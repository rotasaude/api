# /vector_control/households (módulo 35a, ADR 0054; contrato §2, §12; Q2, Q8,
# Q13(5)): o imóvel do 24a na vigilância ambiental.
#   - GET /households (só a coordenação): domicílios ativos, filtrados por
#     bairro da versão atual, quarteirão do perfil ou sem quarteirão; lista
#     `{ items, next_before }` de VectorHousehold, mais recente primeiro, com
#     a trilha territory_registry (TerritoryRegistry::Trail.households_listed!)
#     uma vez por microárea presente na página; nunca morador.
#   - POST /households/assign_block e PATCH /households/:id/profile (só a
#     coordenação): o perfil, nunca o 24a.
#   - GET /households/:id (Q13(5)): `{ id, neighborhood_id, vector }` para a
#     coordenação e para o agente de endemias nas microáreas atribuídas a ele
#     (outra microárea → 404; outro profissional de campo → 403
#     cbo_not_allowed). Sem endereço nem morador: sem trilha. O
#     TerritoryRegistry::Json.household do 24a não muda.
module VectorControl
  class HouseholdsController < BaseController
    before_action(only: %i[assign_block update_profile]) { query_only! }
    before_action :coordinator!, only: %i[index assign_block update_profile]

    def index
      return unless query_only!(:neighborhood_id, :city_block_id, :without_block, :before, :limit)

      neighborhood_id = query_uuid("neighborhood_id")
      return if performed?

      block_id = query_uuid("city_block_id")
      return if performed?

      without_block = request.query_parameters["without_block"]
      return render_refusal("invalid_request", path: "without_block") unless [ nil, "true", "false" ].include?(without_block)

      limit = page_limit
      return unless limit

      position = cursor
      return if performed?

      scope = Household.where(status: "active").includes(:micro_area)
      scope = scope.where(id: current_versions.where(neighborhood_id: neighborhood_id).select(:household_id)) if neighborhood_id
      scope = scope.where(id: HouseholdVectorProfile.where(city_block_id: block_id).select(:household_id)) if block_id
      if without_block == "true"
        scope = scope.where.not(id: HouseholdVectorProfile.where.not(city_block_id: nil).select(:household_id))
      end
      households, next_before = page(scope, :registered_at, limit: limit, position: position)
      households.group_by(&:micro_area_id).each do |micro_area_id, rows|
        TerritoryRegistry::Trail.households_listed!(user: Current.user, micro_area_id: micro_area_id, household_ids: rows.map(&:id))
      end
      render json: { items: Json.household_rows(households), next_before: next_before }
    end

    def show
      return unless query_only!

      household = uuid?(params[:id]) ? Household.includes(micro_area: :team).find_by(id: params[:id]) : nil
      return unless readable?(household)

      neighborhood_id = SaveProfile.current_neighborhood_ids([ household.id ])[household.id]
      render json: { id: household.id, neighborhood_id: neighborhood_id,
                     vector: Json.profile(HouseholdVectorProfile.find_by(household_id: household.id)) }
    end

    def assign_block
      unknown = (body.keys - %w[household_ids city_block_id]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      result = AssignBlock.call(household_ids: body_param("household_ids"), city_block_id: body_param("city_block_id"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: { assigned: result.payload[:assigned] }
    end

    def update_profile
      household = uuid?(params[:id]) ? Household.includes(:micro_area).find_by(id: params[:id]) : nil
      return not_found unless household

      result = SaveProfile.call(household: household, params: body, by: Current.user)
      return render_failure(result) if result.failure?

      TerritoryRegistry::Trail.households_listed!(user: Current.user, micro_area_id: household.micro_area_id, household_ids: [ household.id ])
      render json: Json.household_rows([ household ]).first
    end

    private

    def current_versions = HouseholdVersion.joins(:household).where("household_versions.version = households.version")

    # Coordenação: qualquer domicílio. Agente de endemias: só nas microáreas
    # atribuídas a ele (senão 404). Outro profissional de campo → 403
    # cbo_not_allowed; o resto → 403 missing_role. Renderiza e devolve false.
    def readable?(household)
      user = Current.user
      return true if household && Access.coordinator?(user)
      return not_found_false if Access.coordinator?(user)

      if Access.field_agent_somewhere?(user)
        area = household&.micro_area
        return true if area && Access.field_agent?(user, area.team) && HomeVisits::Access.reads_micro_area?(user, area)

        return not_found_false
      end
      forbid(HomeVisits::Access.registers_somewhere?(user) ? "cbo_not_allowed" : "missing_role")
      false
    end

    def not_found_false
      not_found
      false
    end
  end
end
