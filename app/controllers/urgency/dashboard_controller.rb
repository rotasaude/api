# GET /urgency/dashboard?month=YYYY-MM&health_unit_id= (ADR 0050; contrato
# §11 e §14 Q15, Q25): o painel do gestor, só contagens, com "lt5" de 1 a 4
# (Urgency::Dashboard). Lêem municipal_admin e analyst (todas as UPAs ativas,
# ou a pedida); os demais → 403 missing_role. Sem trilha (nenhum dado de
# paciente sai). `month` padrão = mês corrente; fora de "YYYY-MM" ou futuro →
# 422 invalid_request `month`; `health_unit_id` fora das UPAs ativas → 422
# invalid_request `health_unit_id`. O padrão do Psychosocial::DashboardController.
module Urgency
  class DashboardController < BaseController
    include ::MonthParam

    ROLES = %w[municipal_admin analyst].freeze

    def show
      return forbid unless ROLES.any? { |role| Current.user.has_role?(role) }
      return unless query_only!("month", "health_unit_id")

      query = request.query_parameters
      month = query.key?("month") ? month_from(query["month"]) : Time.zone.today.beginning_of_month
      return render_refusal("month") if month.nil? || month > Time.zone.today.beginning_of_month

      units = units_in_scope(query["health_unit_id"])
      render json: Dashboard.call(units: units, month: month) if units
    end

    private

    # UPAs do painel; renderiza a recusa e devolve nil quando ela existe.
    def units_in_scope(health_unit_id)
      scope = HealthUnit.where(kind: "upa", active: true)
      return scope.to_a if health_unit_id.nil?

      unit = uuid?(health_unit_id) ? scope.find_by(id: health_unit_id) : nil
      return [ unit ] if unit

      render_refusal("health_unit_id")
      nil
    end
  end
end
