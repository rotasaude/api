# Painel do admin municipal (contrato §7): municipal_admin, só leitura.
module Signatures
  class AdminController < BaseController
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    DEFAULT_DAYS = 30

    skip_before_action :require_professional
    before_action :require_manager

    def overview
      range = period
      return render(json: { error: "invalid_period" }, status: :unprocessable_entity) unless range

      render json: AdminOverview.call(range: range)
    end

    private

    def require_manager
      forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
    end

    # from/to "AAAA-MM-DD" no fuso da cidade (Time.zone dentro do request).
    def period
      from = date(params[:from])
      to = date(params[:to])
      return nil if from == :invalid || to == :invalid

      finish = (to || Time.zone.today).in_time_zone.end_of_day
      start = (from || (finish.to_date - (DEFAULT_DAYS - 1))).in_time_zone.beginning_of_day
      start <= finish ? start..finish : nil
    end

    def date(value)
      return nil if value.blank?
      return :invalid unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value)
    rescue Date::Error
      :invalid
    end
  end
end
