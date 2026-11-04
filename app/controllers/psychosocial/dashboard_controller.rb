# GET /psychosocial/dashboard?month=YYYY-MM&health_unit_id= (ADR 0049; contrato
# §11, P11, P46): só contagens, com "lt5" para valor de 1 a 4. Lê a coordenação
# (psychosocial_lead, só os CAPS em que está lotada), municipal_admin e analyst
# (todos os CAPS ativos); os demais → 403 missing_role. Sem trilha (nenhum dado
# de paciente sai). `month` padrão = mês corrente; fora de "YYYY-MM" ou futuro →
# 422 invalid_request `month`; `health_unit_id` fora dos CAPS ativos → 422
# invalid_request; CAPS em que a coordenação não está lotada → 403 not_on_caps_team.
module Psychosocial
  class DashboardController < BaseController
    ALL_UNITS_ROLES = %w[municipal_admin analyst].freeze

    def show
      user = Current.user
      all = ALL_UNITS_ROLES.any? { |role| user.has_role?(role) }
      return forbid unless all || Access.lead?(user)
      return unless query_only!("month", "health_unit_id")

      query = request.query_parameters
      month = query.key?("month") ? month_from(query["month"]) : Time.zone.today.beginning_of_month
      return render_refusal("month") if month.nil? || month > Time.zone.today.beginning_of_month

      units = units_in_scope(all, query["health_unit_id"])
      render json: Dashboard.call(units: units, month: month) if units
    end

    private

    # CAPS do painel; renderiza a recusa e devolve nil quando ela existe.
    def units_in_scope(all, health_unit_id)
      scope = HealthUnit.where(kind: "caps", active: true)
      if health_unit_id.nil?
        return all ? scope.to_a : scope.where(id: Access.staffed_unit_ids(Current.user)).to_a
      end

      unit = uuid?(health_unit_id) ? scope.find_by(id: health_unit_id) : nil
      unless unit
        render_refusal("health_unit_id")
        return nil
      end
      return [ unit ] if all || Access.link(Current.user, unit.id)

      forbid("not_on_caps_team")
      nil
    end
  end
end
