# /vector_control/due (módulo 35a, ADR 0054; contrato §5, §12; Q8):
#   GET /due?micro_area_id=&before=&limit= → `{ items, next_before }` de
#   DueItem (VectorControl::Due), "Imóveis a visitar" do agente de combate às
#   endemias na microárea atribuída a ele. micro_area_id ausente ou não UUID →
#   422 invalid_request; microárea desconhecida → 404; outro vínculo da equipe
#   (ACS, enfermeiro…) → 403 cbo_not_allowed; fora da equipe ou da microárea →
#   403 out_of_scope; limit fora de 1–100 → invalid_limit; cursor adulterado →
#   invalid_cursor. A página traz o endereço curto do 24a: grava a trilha
#   territory_registry (TerritoryRegistry::Trail.households_listed!) com os
#   ids mostrados. "Hoje" é o dia da cidade. Nunca morador.
module VectorControl
  class DueController < BaseController
    def index
      return unless query_only!(:micro_area_id, :before, :limit)

      id = request.query_parameters["micro_area_id"]
      return render_refusal("invalid_request", path: "micro_area_id") unless uuid?(id)

      area = MicroArea.includes(:team).find_by(id: id)
      return not_found unless area

      limit = page_limit
      return unless limit

      result = Due.page(user: Current.user, team: area.team, micro_area: area, before: request.query_parameters["before"].presence,
                        limit: limit, today: Time.zone.today)
      return render_failure(result) if result.failure?

      ids = result.payload[:items].map { |item| item[:household_id] }
      TerritoryRegistry::Trail.households_listed!(user: Current.user, micro_area_id: area.id, household_ids: ids) if ids.any?
      render json: result.payload
    end
  end
end
