# Painel do admin municipal (contrato §7): municipal_admin, só leitura.
module Signatures
  class AdminController < BaseController
    include ReportPeriod

    DEFAULT_DAYS = 30

    skip_before_action :require_professional
    before_action :require_manager

    def overview
      range = resolved_period
      return if performed?

      render json: AdminOverview.call(range: range)
    end

    private

    def require_manager
      forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
    end

    # ReportPeriod: from/to "AAAA-MM-DD" no fuso da cidade; padrão: os últimos
    # 30 dias até hoje. Retorna nil quando inválido (já respondeu 422).
    def resolved_period
      from, to = period
      return render_invalid_period if invalid_period?(from, to)

      finish = to || Time.zone.today.end_of_day
      start = from || (finish.to_date - (DEFAULT_DAYS - 1)).in_time_zone.beginning_of_day
      return render_invalid_period if start > finish

      start..finish
    end
  end
end
