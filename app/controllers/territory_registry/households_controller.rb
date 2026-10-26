# /territory/households (contrato §4, §14 L11; F-24.4): quem cadastra da
# equipe (enfermeiro/médico em qualquer microárea dela, o ACS só na sua).
# Leitura nominal com trilha (clinical_record.viewed, uma por consulta, só
# ids); domicílio de microárea que o usuário não enxerga por id → 404, lista
# de microárea alheia → 403 out_of_scope. Escrita só pelo corpo JSON.
module TerritoryRegistry
  class HouseholdsController < BaseController
    def index
      # Sem microárea (ou não-UUID) → 422 invalid_request (L12); desconhecida → 404.
      return render_error("invalid_request") unless uuid?(params[:micro_area_id])

      area = MicroArea.find_by(id: params[:micro_area_id])
      return not_found unless area
      return forbid("out_of_scope") unless visible?(area.id, area.team)

      limit = page_limit
      return unless limit

      # Mais recente primeiro (registered_at DESC, id DESC); o cursor opaco
      # leva os dois (revisão final, m5).
      scope = Household.where(micro_area_id: area.id).order(registered_at: :desc, id: :desc)
      if params[:before].present?
        cursor = decode_cursor(params[:before])
        return render_error("invalid_cursor") unless cursor

        scope = scope.where("(households.registered_at, households.id) < (?, ?)", *cursor)
      end
      rows = scope.limit(limit + 1).includes(:micro_area, registered_by_user: :professional).to_a
      page = rows.first(limit)
      Trail.households_listed!(user: Current.user, micro_area_id: area.id, household_ids: page.map(&:id))
      render json: { households: rendered(page, full: false), next_before: rows.size > limit ? encode_cursor(page.last) : nil }
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

    def encode_cursor(household) = Base64.urlsafe_encode64("#{household.registered_at.utc.iso8601(6)}|#{household.id}", padding: false)

    # [registered_at, id] ou nil (cursor que não veio daqui).
    def decode_cursor(raw)
      at, id = Base64.urlsafe_decode64(raw.to_s).split("|", 2)
      time = Time.iso8601(at.to_s)
      uuid?(id) ? [ time, id ] : nil
    rescue ArgumentError
      nil
    end

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
      rows = Family.where(household_id: ids).includes(:responsible_patient).order(:created_at, :id).to_a
      exited = Families.responsible_exited_ids(rows)
      families = rows.group_by(&:household_id)
      households.map do |household|
        Json.household(household, versions.fetch(household.id), families: families[household.id] || [], exited: exited, full: full)
      end
    end
  end
end
