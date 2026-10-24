# /territory/households (contrato §4, §14 L11; F-24.4): quem cadastra da
# equipe (enfermeiro/médico em qualquer microárea dela, o ACS só na sua).
# Leitura nominal com trilha (clinical_record.viewed, uma por consulta, só
# ids); domicílio de microárea que o usuário não enxerga por id → 404, lista
# de microárea alheia → 403 out_of_scope. Escrita só pelo corpo JSON.
module TerritoryRegistry
  class HouseholdsController < BaseController
    def index
      area = uuid?(params[:micro_area_id]) && MicroArea.find_by(id: params[:micro_area_id])
      return not_found unless area
      return forbid("out_of_scope") unless visible?(area.id, area.team)

      limit = page_limit
      return unless limit

      scope = Household.where(micro_area_id: area.id).order(id: :desc)
      if params[:before].present?
        return render_error("invalid_cursor") unless uuid?(params[:before])

        scope = scope.where("households.id < ?", params[:before])
      end
      rows = scope.limit(limit + 1).includes(:micro_area, registered_by_user: :professional).to_a
      page = rows.first(limit)
      Trail.households_listed!(user: Current.user, micro_area_id: area.id, household_ids: page.map(&:id))
      render json: { households: rendered(page, full: false), next_before: rows.size > limit ? page.last.id : nil }
    end

    def show
      household = find_household
      return not_found unless household

      Trail.household_viewed!(user: Current.user, household_id: household.id)
      render json: rendered([ household ], full: true).first
    end

    def create
      result = SaveHousehold.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: rendered([ result.payload[:household] ], full: true).first, status: :created
    end

    def update
      household = find_household
      return not_found unless household

      result = SaveHousehold.call(params: body, by: Current.user, household: household)
      return render_failure(result) if result.failure?

      render json: rendered([ result.payload[:household] ], full: true).first
    end

    private

    def find_household
      household = uuid?(params[:id]) && Household.includes(micro_area: :team).find_by(id: params[:id])
      household if household && visible?(household.micro_area_id, household.micro_area.team)
    end

    def visible?(micro_area_id, team) = Access.visible_micro_area_ids(Current.user, team).include?(micro_area_id)

    # A última versão de cada domicílio e as famílias, sem N+1.
    def rendered(households, full:)
      ids = households.map(&:id)
      versions = HouseholdVersion.joins(:household).where(household_id: ids).where("household_versions.version = households.version")
                                 .index_by(&:household_id)
      families = Family.where(household_id: ids).includes(:responsible_patient).order(:created_at, :id).group_by(&:household_id)
      households.map do |household|
        Json.household(household, versions.fetch(household.id), families: families[household.id] || [], full: full)
      end
    end
  end
end
