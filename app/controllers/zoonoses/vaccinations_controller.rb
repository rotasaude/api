# /zoonoses/vaccinations (módulo 35b, ADR 0054; contrato §3, §10, §16): a dose
# antirrábica, para team? (403 missing_role).
#   - POST /vaccinations (Zoonoses::RecordVaccination, origin "dashboard"; o
#     gate de campo do casa a casa lido aqui, fora da transação) → 201 com a
#     dose; com evento adverso, `reminder` (o lembrete fixo do EATAV);
#   - POST /vaccinations/:id/cancel `{ reason }` (Zoonoses::CancelVaccination)
#     → a dose;
#   - GET /vaccinations?campaign_id=&from=&to=&modality=&before=&limit= →
#     `{ items, next_before }`, mais recente primeiro (50 por página, até 100),
#     de/até pelo dia da dose. Sem tutor, nome do animal, nota nem motivo.
# A escrita recusa query (422 invalid_request); a lista recusa chave fora dos
# filtros.
module Zoonoses
  class VaccinationsController < BaseController
    FILTERS = %i[campaign_id from to modality before limit].freeze
    KEY_PATH_MAX = 64

    before_action :team!
    before_action(only: %i[create cancel]) { query_only! }

    def index
      return unless query_only!(*FILTERS)

      scope = filtered
      return if performed?

      limit = page_limit
      return unless limit

      position = CareLines::Cursor.decode(request.query_parameters["before"])
      rows, next_before = page(scope, :created_at, limit: limit, position: position)
      render json: { items: rows.map { Json.rabies_vaccination(_1) }, next_before: next_before }
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
    end

    def create
      result = RecordVaccination.call(params: body, by: Current.user, origin: "dashboard",
                                      zoonoses_field: Gate.field_usable?(Current.city))
      return render_failure(result) if result.failure?

      vaccination = result.payload.fetch(:vaccination)
      json = Json.rabies_vaccination(vaccination)
      json[:reminder] = Catalog::ADVERSE_REMINDER if vaccination.adverse_event
      render json: json, status: :created
    end

    def cancel
      vaccination = uuid?(params[:id]) ? RabiesVaccination.find_by(id: params[:id]) : nil
      return not_found unless vaccination

      extra = (body.keys - %w[reason]).first
      return render_refusal("invalid_request", path: extra.to_s[0, KEY_PATH_MAX]) if extra

      result = CancelVaccination.call(vaccination: vaccination, reason: body["reason"], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.rabies_vaccination(result.payload.fetch(:vaccination))
    end

    private

    # O escopo dos filtros; recusado, já respondeu 422 (performed?).
    def filtered
      scope = RabiesVaccination.all
      campaign_id = query_uuid("campaign_id")
      return if performed?

      from = query_date("from")
      return if performed?

      to = query_date("to")
      return if performed?

      modality = request.query_parameters["modality"]
      return render_refusal("invalid_request", path: "modality") if modality && !Catalog::MODALITIES.include?(modality)

      scope = scope.where(campaign_id: campaign_id) if campaign_id
      scope = scope.where(vaccinated_on: from..) if from
      scope = scope.where(vaccinated_on: ..to) if to
      scope = scope.where(modality: modality) if modality
      scope
    end
  end
end
