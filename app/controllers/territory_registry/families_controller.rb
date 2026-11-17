# /territory/households/:id/families e /territory/families/:id (contrato §4;
# F-24.4): a família grava e gera a versão seguinte do domicílio com a ficha
# (TerritoryRegistry::SaveFamily). Domicílio que o usuário não enxerga → 404.
# A resposta é o <household> atualizado (o autor vê o que gravou; sem trilha).
# Módulo 35a (Q13(1)): o agente de endemias enxerga, com vector_control, o
# imóvel das microáreas atribuídas a ele, mas família é dele nunca → 403
# cbo_not_allowed (quem não enxerga segue 404).
# POST /territory/families/:id/replace_responsible (§14 L29): troca do
# responsável = família nova (TerritoryRegistry::ReplaceResponsible), 201.
module TerritoryRegistry
  class FamiliesController < BaseController
    def create
      household = visible_household(params[:id])
      return refuse_missing(params[:id]) unless household

      respond(SaveFamily.call(household: household, params: body, by: Current.user), :created)
    end

    def update
      family = uuid?(params[:id]) && Family.find_by(id: params[:id])
      household = family && visible_household(family.household_id)
      return refuse_missing(family&.household_id) unless household

      respond(SaveFamily.call(household: household, params: body, by: Current.user, family: family), :ok)
    end

    def replace_responsible
      family = uuid?(params[:id]) && Family.find_by(id: params[:id])
      household = family && visible_household(family.household_id)
      return refuse_missing(family&.household_id) unless household

      respond(ReplaceResponsible.call(family: family, params: body, by: Current.user), :created)
    end

    private

    def visible_household(id)
      household = uuid?(id) && Household.includes(micro_area: :team).find_by(id: id)
      return nil unless household

      household if Access.visible_micro_area_ids(Current.user, household.micro_area.team).include?(household.micro_area_id)
    end

    # Fora da visibilidade de quem cadastra: o agente de endemias no imóvel
    # das microáreas dele → 403 cbo_not_allowed; o resto → 404.
    def refuse_missing(household_id)
      household = uuid?(household_id) && Household.includes(micro_area: :team).find_by(id: household_id)
      endemic = household && Access.visible_micro_area_ids(Current.user, household.micro_area.team, vector_control: vector_control_usable?)
                                    .include?(household.micro_area_id)
      endemic ? forbid("cbo_not_allowed") : not_found
    end

    def respond(result, status)
      return render_failure(result) if result.failure?

      household = result.payload[:household]
      families = Family.where(household_id: household.id).includes(:responsible_patient).order(:created_at, :id).to_a
      exited = Families.responsible_exited_ids(families)
      render json: Json.household(household, result.payload[:version], families: families, exited: exited), status: status
    end
  end
end
