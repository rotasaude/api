# /vector_control/ovitraps (módulo 35a, ADR 0054; contrato §6, §12; Q7(2),
# Q8, Q13(2)):
#   - GET /ovitraps?micro_area_id= (o agente de endemias, com a microárea no
#     escopo; senão 403 out_of_scope / cbo_not_allowed / missing_role) ou
#     ?neighborhood_id= (a coordenação e o vector_lab; senão 403 missing_role;
#     o bairro do quarteirão congelado), um dos dois (nenhum ou os dois → 422
#     invalid_request path micro_area_id), com `status` opcional e `before`:
#     `{ items, next_before }` de Ovitrap, mais recente primeiro;
#   - POST /ovitraps (VectorControl::InstallOvitrap) → 201 Ovitrap (200 no
#     replay do client_uuid);
#   - POST /ovitraps/:id/collect (VectorControl::CollectOvitrap) → Ovitrap.
# A Ovitrap traz o endereço curto do 24a: toda resposta grava a trilha
# territory_registry (TerritoryRegistry::Trail.households_listed!) uma vez por
# microárea. Nunca morador; os pontos do mapa saem pelo GET /map_points.
module VectorControl
  class OvitrapsController < BaseController
    LIMIT = 50

    before_action(only: %i[create collect]) { query_only! }

    def index
      return unless query_only!(:micro_area_id, :neighborhood_id, :status, :before)

      status = request.query_parameters["status"]
      return render_refusal("invalid_request", path: "status") unless status.nil? || Ovitrap::STATUSES.include?(status)

      scope = listed_scope
      return if performed?

      position = cursor
      return if performed?

      scope = scope.where(status: status) if status
      rows, next_before = page(scope, :created_at, limit: LIMIT, position: position)
      render json: { items: shown(rows), next_before: next_before }
    end

    def create
      result = InstallOvitrap.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: shown([ result.payload[:ovitrap] ]).sole, status: result.payload[:replayed] ? :ok : :created
    end

    def collect
      ovitrap = Ovitrap.includes(household: { micro_area: :team }).find_by(id: params[:id])
      return not_found unless ovitrap

      result = CollectOvitrap.call(ovitrap: ovitrap, params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: shown([ result.payload[:ovitrap] ]).sole
    end

    private

    # O escopo da lista pelo filtro e por quem lê; nil = já respondeu.
    def listed_scope
      query = request.query_parameters
      return render_refusal("invalid_request", path: "micro_area_id") if query.key?("micro_area_id") == query.key?("neighborhood_id")

      query.key?("micro_area_id") ? micro_area_scope : neighborhood_scope
    end

    def micro_area_scope
      id = query_uuid("micro_area_id")
      return if performed?

      area = MicroArea.includes(:team).find_by(id: id)
      return not_found unless area

      refusal = Access.agent_refusal(Current.user, area)
      return forbid(refusal) if refusal

      Ovitrap.where(household_id: Household.where(micro_area_id: area.id).select(:id))
    end

    def neighborhood_scope
      return forbid unless Access.coordinator?(Current.user) || Access.lab?(Current.user)

      id = query_uuid("neighborhood_id")
      return if performed?

      neighborhood = Neighborhood.find_by(id: id)
      return not_found unless neighborhood

      Ovitrap.where(city_block_id: CityBlock.where(neighborhood_id: neighborhood.id).select(:id))
    end

    # Ovitrap[] das linhas, com a trilha do endereço curto por microárea.
    def shown(ovitraps)
      areas = Household.where(id: ovitraps.map(&:household_id).uniq).pluck(:id, :micro_area_id).to_h
      ovitraps.map(&:household_id).uniq.group_by { |id| areas.fetch(id) }.each do |micro_area_id, household_ids|
        TerritoryRegistry::Trail.households_listed!(user: Current.user, micro_area_id: micro_area_id, household_ids: household_ids)
      end
      Json.ovitraps(ovitraps)
    end
  end
end
