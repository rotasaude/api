# GET /admin/api/overview — KPIs operacionais (§4.0).
#
# Mix de fontes: usa dashboard_metrics quando existem (source: proj),
# cai para agregação ao vivo (source: live) quando não há projeção
# correspondente. Cada KPI carrega seu source no contrato (§7).
class Admin::OverviewQuery
  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    {
      kpis: [
        kpi_done,
        kpi_active,
        kpi_priority,
        kpi_completion,
        kpi_failed_jobs
      ]
    }
  end

  private

  def kpi_done
    completed = Admin::Scoped.triages(@muni)
                  .where(status: "completed", completed_at: @period.from..@period.to)
                  .count
    {
      id: "done",
      label: "Triagens concluídas",
      value: completed,
      unit: "",
      delta: nil,
      tone: completed.positive? ? "ok" : "neutral",
      spark: @period.series(Admin::Scoped.triages(@muni).where(status: "completed"), :completed_at),
      source: "live"
    }
  end

  def kpi_active
    active = Admin::Scoped.conversations(@muni)
               .where(state: %w[awaiting_consent consented])
               .where(updated_at: 1.hour.ago..)
               .count
    {
      id: "active",
      label: "Conversas ativas agora",
      value: active,
      unit: "",
      delta: nil,
      tone: "info",
      spark: @period.series(Admin::Scoped.conversations(@muni), :updated_at),
      source: "live"
    }
  end

  def kpi_priority
    priority = Admin::Scoped.triages(@muni)
                 .where(priority: true, created_at: @period.from..@period.to)
                 .count
    {
      id: "priority",
      label: "Casos priority",
      value: priority,
      unit: "",
      delta: nil,
      tone: priority.positive? ? "warn" : "ok",
      spark: @period.series(Admin::Scoped.triages(@muni).where(priority: true), :created_at),
      source: "live"
    }
  end

  def kpi_completion
    base = Admin::Scoped.triages(@muni).where(created_at: @period.from..@period.to)
    started = base.count
    completed = base.where(status: "completed").count
    rate = started.zero? ? 0.0 : (completed.to_f / started * 100).round(1)
    {
      id: "completion",
      label: "Taxa de conclusão",
      value: rate,
      unit: "%",
      delta: nil,
      tone: rate >= 70 ? "ok" : (rate >= 40 ? "warn" : "down"),
      spark: [],
      source: "live"
    }
  end

  # Infraestrutura — cross-tenant por natureza (Solid Queue não conhece muni).
  def kpi_failed_jobs
    failed = SolidQueue::FailedExecution.count
    {
      id: "failed",
      label: "Jobs falhados abertos",
      value: failed,
      unit: "",
      delta: nil,
      tone: failed.zero? ? "ok" : (failed < 5 ? "warn" : "down"),
      spark: [],
      source: "live"
    }
  end
end
