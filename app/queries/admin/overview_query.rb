# GET /admin/api/overview — KPIs operacionais (§4.0).
#
# Todos os KPIs agregam ao vivo no banco da cidade (ADR 0022; source: live).
# O campo source continua no contrato (§7) para quando um KPI passar a ler
# projeção por ADR novo. Urgência = régua do alerta (Protocols::Urgency).
class Admin::OverviewQuery
  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    {
      kpis: [
        kpi_done,
        kpi_active,
        kpi_urgent,
        kpi_completion,
        kpi_failed_jobs
      ]
    }
  end

  private

  def kpi_done
    completed = Triage.all
                  .where(status: "completed", completed_at: @period.from..@period.to)
                  .count
    {
      id: "done",
      label: "Triagens concluídas",
      value: completed,
      unit: "",
      delta: nil,
      tone: completed.positive? ? "ok" : "neutral",
      spark: @period.series(Triage.all.where(status: "completed"), :completed_at),
      source: "live"
    }
  end

  def kpi_active
    active = Conversation.all
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
      spark: @period.series(Conversation.all, :updated_at),
      source: "live"
    }
  end

  def kpi_urgent
    urgent = Triage.all.where(status: "completed", priority: ..Protocols::Urgency.max_priority)
    count = urgent.where(completed_at: @period.from..@period.to).count
    {
      id: "urgent",
      label: "Casos urgentes",
      value: count,
      unit: "",
      delta: nil,
      tone: count.positive? ? "warn" : "ok",
      spark: @period.series(urgent, :completed_at),
      source: "live"
    }
  end

  def kpi_completion
    base = Triage.all.where(created_at: @period.from..@period.to)
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

  # Infraestrutura — o Solid Queue mora no banco da cidade desde o Plano 5:
  # este número é só desta cidade (city_connection_queue_spec).
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
