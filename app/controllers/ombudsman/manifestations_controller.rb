# /ombudsman/manifestations (ADR 0051; contrato §5). Nesta altura só:
#   POST /ombudsman/manifestations → 201 { id, protocol, due_on }
#     registro pela equipe (técnico ou ouvidor): canal in_person | phone |
#     ouvidorsus (Ombudsman::Register com `by:`); anexos do usuário.
#   GET  /ombudsman/manifestations/:id/receipt → { protocol, kind,
#     received_at, due_on, channel }; a anônima → 404.
# Texto, nome, contato e CPF só do corpo JSON; chave fora da lista no corpo ou
# qualquer chave na query → 422 com o path (só o nome da chave).
module Ombudsman
  class ManifestationsController < BaseController
    CREATE_KEYS = %w[kind identification_mode channel ouvidorsus_number citizen_id manifestant_name manifestant_contact
                     manifestant_cpf body health_unit_id attachment_ids].freeze

    before_action :require_staff!
    before_action :load_manifestation, only: :receipt

    def create
      return unless query_only!

      unknown = (body.keys - CREATE_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      channel = body_param("channel")
      return render_refusal("channel") unless Catalog::STAFF_CHANNELS.include?(channel)

      result = Register.call(attrs: body.except("channel"), channel: channel, by: Current.user)
      return render_failure(result) if result.failure?

      manifestation = result.payload.fetch(:manifestation)
      render json: { id: manifestation.id, protocol: manifestation.protocol, due_on: due_on(manifestation) }, status: :created
    end

    def receipt
      return not_found if @manifestation.anonymous?

      render json: { protocol: @manifestation.protocol, kind: @manifestation.kind, received_at: @manifestation.received_at.iso8601,
                     due_on: due_on(@manifestation), channel: @manifestation.channel }
    end

    private

    def due_on(manifestation) = Deadlines.due_on(manifestation, OmbudsmanSetting.current, today: Time.zone.today).iso8601
  end
end
