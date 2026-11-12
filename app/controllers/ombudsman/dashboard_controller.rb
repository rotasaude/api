# GET /ombudsman/dashboard e /dashboard/professionals (ADR 0051; contrato §11;
# §16 Q28): o painel (técnico e ouvidor, com supressão) e a contagem por
# profissional referido (só o ouvidor, sem supressão). `from`/`to` "AAAA-MM-DD"
# (ReportPeriod); padrão: do começo do ano até hoje; inválido ou invertido →
# 422 invalid_period. Só agregados: nenhum texto, nenhuma trilha.
module Ombudsman
  class DashboardController < BaseController
    include ::ReportPeriod

    before_action :require_staff!, only: :show
    before_action :require_ombudsman_role!, only: :professionals

    def show
      range = requested_range or return
      render json: Panel.call(from: range.first, to: range.last, today: Time.zone.today)
    end

    def professionals
      range = requested_range or return
      render json: { items: Panel.professionals(from: range.first, to: range.last) }
    end

    private

    # [from, to] (datas) ou nil, já renderizada a recusa.
    def requested_range
      return unless query_only!("from", "to")

      from, to = period
      return refuse_period if invalid_period?(from, to)

      today = Time.zone.today
      from = from ? from.to_date : today.beginning_of_year
      to = to ? to.to_date : today
      return refuse_period if from > to

      [ from, to ]
    end

    def refuse_period
      render_invalid_period
      nil
    end
  end
end
