# Painel do transporte e do TFD (ADR 0048; contrato §9, §14 T16):
#   GET /transport/dashboard?month=YYYY-MM
# municipal_admin, transport_dispatcher e tfd_committee; só números, sem
# trilha. Sem `month`, o mês corrente (calendário do fuso da cidade). `month`
# inválido → 422 (path "month"). O interruptor do TFD é lido aqui, fora de
# transação.
module Transport
  class DashboardController < BaseController
    MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/

    before_action { forbid unless admin? || Access.dispatcher?(Current.user) || Access.committee?(Current.user) }

    def show
      return unless query_only!(:month)

      month = params.key?(:month) ? params[:month] : Time.zone.today.strftime("%Y-%m")
      return render_refusal("month") unless valid_month?(month)

      render json: Dashboard.call(month: month, tfd_enabled: Tfd::Gate.usable?(Current.city))
    end

    private

    def valid_month?(month)
      match = month.is_a?(String) && MONTH.match(month)
      match.present? && (2000..2100).cover?(match[1].to_i)
    end
  end
end
