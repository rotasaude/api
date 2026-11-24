# /zoonoses/collars (módulo 35b, ADR 0054; contrato §6, §10, Q23), para team?
# (403 missing_role).
#   - POST /collars (Zoonoses::PlaceCollar, origin "dashboard") → 201 com a
#     coleira; a anterior ativa sai com `replaced` na mesma transação;
#   - POST /collars/:id/remove `{ reason, removed_on? }` (Zoonoses::RemoveCollar)
#     → a coleira; já retirada ou trocada → 409 collar_changed;
#   - GET /collars?due=1 → `{ items }` das coleiras ativas de cães `active` com due_on até hoje +
#     15 dias, as mais atrasadas primeiro, com animal_id, household_id e due_on.
#     Sem tutor, nome nem microchip.
# A escrita recusa query (422 invalid_request); a lista só aceita `due`.
module Zoonoses
  class CollarsController < BaseController
    KEY_PATH_MAX = 64

    before_action :team!
    before_action(only: %i[create remove]) { query_only! }

    def index
      return unless query_only!(:due)
      return render_refusal("invalid_request", path: "due") unless request.query_parameters["due"] == "1"

      limit = Time.zone.today + Catalog::COLLAR_DUE_WINDOW
      rows = Collar.active.joins(:animal).merge(Animal.active).where(due_on: ..limit).order(:due_on, :id)
                   .pluck("collars.id", "collars.animal_id", "animals.household_id", "collars.vector_product_id", "collars.placed_on",
                          "collars.due_on")
      render json: { items: rows.map { |id, animal_id, household_id, product_id, placed_on, due_on|
        { id: id, animal_id: animal_id, household_id: household_id, vector_product_id: product_id, placed_on: placed_on.iso8601,
          due_on: due_on.iso8601 }
      } }
    end

    def create
      result = PlaceCollar.call(params: body, by: Current.user, origin: "dashboard")
      return render_failure(result) if result.failure?

      render json: Json.collar_record(result.payload.fetch(:collar)), status: :created
    end

    def remove
      collar = uuid?(params[:id]) ? Collar.find_by(id: params[:id]) : nil
      return not_found unless collar

      extra = (body.keys - %w[reason removed_on]).first
      return render_refusal("invalid_request", path: extra.to_s[0, KEY_PATH_MAX]) if extra

      result = RemoveCollar.call(collar: collar, reason: body["reason"], removed_on: body["removed_on"], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.collar_record(result.payload.fetch(:collar))
    end
  end
end
