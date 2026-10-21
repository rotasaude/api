# /billing/periods (contrato §5 com B6, B8, B11): faturista e admin leem a
# lista e as pendências (com trilha: tem paciente); só o faturista fecha e
# reabre, com step-up. Ordem: papel → step-up → comando.
module Billing
  class PeriodsController < BaseController
    before_action :require_reader
    before_action :load_period, except: :index

    def index
      competence = params[:competence].presence || Time.zone.today.strftime("%Y%m")
      return invalid_filter unless competence.is_a?(String) && competence.match?(Periods::COMPETENCE)

      periods = BillingPeriod.where(competence: competence).includes(:health_unit, :exam_provider, closed_by_user: :professional).to_a
      render json: { periods: periods.sort_by { |p| [ Establishment.of(p).name.to_s, p.id ] }.map { |p| Json.period(p) } }
    end

    def pending
      items = Pending.call(@period)
      DomainEvents.publish("billing_period.pending_viewed", billing_period_id: @period.id, user_id: Current.user.id)
      render json: { items: items }
    end

    def close
      return forbid unless Access.clerk?(Current.user)
      return require_step_up! unless reauthenticated_recently?

      result = Close.call(period: @period, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.period(@period.reload)
    end

    def reopen
      return forbid unless Access.clerk?(Current.user)
      return require_step_up! unless reauthenticated_recently?

      result = Reopen.call(period: @period, reason: params[:reason], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.period(@period.reload)
    end

    private

    def require_reader = (forbid unless Access.reader?(Current.user))

    def load_period
      @period = uuid?(params[:id]) ? BillingPeriod.find_by(id: params[:id]) : nil
      not_found unless @period
    end
  end
end
