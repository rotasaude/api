#   GET  /citizen/ombudsman/manifestations
#   GET  /citizen/ombudsman/manifestations/:id
#   POST /citizen/ombudsman/manifestations
#        { citizen_id | { cpf, full_name }, kind, identification_mode, body, health_unit_id?, attachment_ids? }
# "Minhas manifestações" e o registro pelo canal do cidadão (ADR 0051; contrato
# §3; §16 U1, Q19, Q40, Q42, Q43, Q45, Q46). A sessão é do TELEFONE: a lista
# traz as manifestações de todos os cidadãos dele (cpf_masked quando há mais de
# um), mais nova primeiro; a anônima não tem cidadão e nunca aparece. O
# `citizen_id` do POST fora da sessão → 403 not_own_citizen (com `cpf` junto,
# antes disso: 422 path cpf); o `:id` de outro cidadão → 404. Sem o cidadão
# na sessão, o POST aceita o par declarado
# `{ cpf, full_name }` (Ombudsman::Register). O detalhe marca como lidos os
# avisos daquela manifestação. Texto, nome e CPF só do corpo JSON: chave fora
# da lista no corpo, ou qualquer chave na query → 422 com o path (só o nome da
# chave). 10 registros por dia por sessão (429 too_many_requests).
# Depois do registro, o cidadão age pela sessão (Task 15; contrato §3, §10):
# POST :id/complement { body, attachment_ids? } (só em awaiting_complement →
# 200, senão 409 manifestation_changed), :id/reopen_request { reason } → 201 e
# :id/satisfaction { met, clear, score } → 201 (sem texto livre). Os três
# respondem o detalhe novo, com os `can_*`; chave fora da lista → 422 com o
# path; manifestação de outro cidadão ou anônima → 404; 30 envios por dia por
# sessão (429 too_many_requests).
module CitizenApi
  module Ombudsman
    class ManifestationsController < CitizenApi::BaseController
      include ::OmbudsmanGate

      wrap_parameters false

      CREATE_KEYS = %w[citizen_id cpf full_name kind identification_mode body health_unit_id attachment_ids].freeze
      KEY_PATH_MAX = 64
      FAILURE_STATUS = { not_own_citizen: :forbidden, not_found: :not_found, manifestation_changed: :conflict,
                         already_answered: :conflict, reopen_pending: :conflict }.freeze

      before_action :require_ombudsman!
      rate_limit to: 10, within: 1.day, only: :create, name: "citizen_ombudsman_manifestation",
                 by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
                 with: -> { render_error("too_many_requests", :too_many_requests) }
      rate_limit to: 30, within: 1.day, only: %i[complement reopen_request satisfaction], name: "citizen_ombudsman_followup",
                 by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
                 with: -> { render_error("too_many_requests", :too_many_requests) }
      before_action :query_only!

      def index
        citizens = current_citizen_session.citizens.to_a
        ids = citizens.map(&:id)
        masked = citizens.size > 1 ? citizens.to_h { |c| [ c.id, c.cpf_masked ] } : {}
        unread = OmbudsmanNotice.where(citizen_id: ids, read_at: nil).distinct.pluck(:ombudsman_manifestation_id).to_set
        settings = OmbudsmanSetting.current
        today = Time.zone.today
        rows = OmbudsmanManifestation.where(citizen_id: ids).order(received_at: :desc, id: :desc)
        render json: {
          manifestations: rows.map do |manifestation|
            ::Ombudsman::CitizenJson.list_item(manifestation, settings: settings, today: today,
                                               cpf_masked: masked[manifestation.citizen_id],
                                               has_unread: unread.include?(manifestation.id))
          end
        }
      end

      def show
        manifestation = own_manifestation
        return render_error("not_found", :not_found) unless manifestation

        OmbudsmanNotice.where(ombudsman_manifestation_id: manifestation.id, citizen_id: manifestation.citizen_id, read_at: nil)
                       .update_all(read_at: Time.current)
        render json: ::Ombudsman::CitizenJson.detail(manifestation, settings: OmbudsmanSetting.current, today: Time.zone.today)
      end

      def create
        attrs = request.request_parameters
        unknown = (attrs.keys - CREATE_KEYS).first
        return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

        # As duas formas de identificação ao mesmo tempo é erro de forma, antes
        # da posse (override T8.1): 422 path cpf mesmo com citizen_id alheio.
        return render_refusal("cpf") unless attrs["citizen_id"].nil? || attrs["cpf"].nil?

        citizen = nil
        unless attrs["citizen_id"].nil?
          citizen = uuid?(attrs["citizen_id"]) ? current_citizen_session.citizens.find_by(id: attrs["citizen_id"]) : nil
          return render_error("not_own_citizen", :forbidden) unless citizen
        end

        result = ::Ombudsman::Register.call(attrs: attrs.except("citizen_id"), channel: "web", citizen: citizen,
                                            citizen_session: current_citizen_session)
        return render_failure(result) if result.failure?

        manifestation = result.payload.fetch(:manifestation)
        due_on = ::Ombudsman::Deadlines.due_on(manifestation, OmbudsmanSetting.current, today: Time.zone.today)
        render json: { id: manifestation.id, protocol: manifestation.protocol, due_on: due_on.iso8601 }, status: :created
      end

      def complement
        follow_up(%w[body attachment_ids], :ok) do |manifestation, attrs|
          ::Ombudsman::RecordComplement.call(
            manifestation: manifestation, expected_state: "awaiting_complement", text: attrs["body"], field: "body",
            attachment_ids: attrs["attachment_ids"], actor: "citizen", by: nil, owner: current_citizen_session
          )
        end
      end

      def reopen_request
        follow_up(%w[reason], :created) do |manifestation, attrs|
          ::Ombudsman::RequestReopen.call(manifestation: manifestation, reason: attrs["reason"])
        end
      end

      def satisfaction
        follow_up(%w[met clear score], :created) do |manifestation, attrs|
          ::Ombudsman::RecordSatisfaction.call(manifestation: manifestation, met: attrs["met"], clear: attrs["clear"],
                                               score: attrs["score"])
        end
      end

      private

      # Os três passos do cidadão: posse (404), chaves do corpo (422 com o path),
      # o comando e o detalhe novo. A chave "met" ausente é recusada pelo comando.
      def follow_up(keys, status)
        manifestation = own_manifestation
        return render_error("not_found", :not_found) unless manifestation

        attrs = request.request_parameters
        unknown = (attrs.keys - keys).first
        return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

        result = yield(manifestation, attrs)
        return render_failure(result) if result.failure?

        render json: ::Ombudsman::CitizenJson.detail(own_manifestation, settings: OmbudsmanSetting.current, today: Time.zone.today),
               status: status
      end

      # A manifestação de um cidadão da sessão, com o que o detalhe lê; nil
      # quando o id não é uuid, não existe, é anônima ou é de outro telefone.
      def own_manifestation
        return nil unless uuid?(params[:id])

        OmbudsmanManifestation.where(citizen_id: current_citizen_session.citizens.select(:id))
                              .includes(:referred_health_unit, :events, :attachments, :reopen_requests, :satisfaction_response)
                              .find_by(id: params[:id])
      end

      # Preflight F-14: nada de dado na URL — qualquer chave na query → 422.
      def query_only!
        unknown = request.query_parameters.keys.first
        render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      end

      def render_failure(result)
        payload = { error: result.reason.to_s }
        %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
        render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
      end

      def render_refusal(path)
        render json: { error: "invalid_request", path: path, problems: [ { error: "invalid_request", path: path } ] },
               status: :unprocessable_entity
      end

      def uuid?(value) = ::Ombudsman::Input.uuid?(value)
    end
  end
end
