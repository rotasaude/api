#   GET  /citizen/ombudsman/manifestations
#   GET  /citizen/ombudsman/manifestations/:id
#   POST /citizen/ombudsman/manifestations
#        { citizen_id | { cpf, full_name }, kind, identification_mode, body, health_unit_id?, attachment_ids? }
# "Minhas manifestações" e o registro pelo canal do cidadão (ADR 0051; contrato
# §3; §16 U1, Q19, Q40, Q42, Q43, Q45, Q46). A sessão é do TELEFONE: a lista
# traz as manifestações de todos os cidadãos dele (cpf_masked quando há mais de
# um), mais nova primeiro; a anônima não tem cidadão e nunca aparece. O
# `citizen_id` do POST fora da sessão → 403 not_own_citizen; o `:id` de outro
# cidadão → 404. Sem o cidadão na sessão, o POST aceita o par declarado
# `{ cpf, full_name }` (Ombudsman::Register). O detalhe marca como lidos os
# avisos daquela manifestação. Texto, nome e CPF só do corpo JSON: chave fora
# da lista no corpo, ou qualquer chave na query → 422 com o path (só o nome da
# chave). 10 registros por dia por sessão (429 too_many_requests).
module CitizenApi
  module Ombudsman
    class ManifestationsController < CitizenApi::BaseController
      include ::OmbudsmanGate

      wrap_parameters false

      CREATE_KEYS = %w[citizen_id cpf full_name kind identification_mode body health_unit_id attachment_ids].freeze
      KEY_PATH_MAX = 64

      before_action :require_ombudsman!
      rate_limit to: 10, within: 1.day, only: :create, name: "citizen_ombudsman_manifestation",
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

      private

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
        render json: payload, status: result.reason == :not_own_citizen ? :forbidden : :unprocessable_entity
      end

      def render_refusal(path)
        render json: { error: "invalid_request", path: path, problems: [ { error: "invalid_request", path: path } ] },
               status: :unprocessable_entity
      end

      def uuid?(value) = value.is_a?(String) && value.match?(::Ombudsman::BaseController::UUID)
    end
  end
end
