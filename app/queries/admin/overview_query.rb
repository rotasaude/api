# GET /admin/api/overview — KPIs operacionais (§4.0).
#
# Todos os KPIs agregam ao vivo no banco da cidade (ADR 0022; source: live).
# O campo source continua no contrato (§7) para quando um KPI passar a ler
# projeção por ADR novo. Urgência = régua do alerta (Protocols::Urgency).
#
# Filtro de bairro (ADR 0023): triagens pelo bairro copiado, conversas pelo
# bairro atual do cidadão; com o filtro ligado, 1 a 4 sai suprimido. Jobs com
# falha não são do cidadão: ignoram o filtro.
class Admin::OverviewQuery
  def self.call(period:, filter: Admin::NeighborhoodFilter.off)
    new(period, filter).call
  end

  def initialize(period, filter)
    @period = period
    @filter = filter
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

  def triages = @filter.triages(Triage.all)
  def conversations = @filter.conversations(Conversation.all)

  def kpi_done
    completed = triages
                  .where(status: "completed", completed_at: @period.from..@period.to)
                  .count
    {
      id: "done",
      label: "Triagens concluídas",
      value: @filter.count(completed),
      unit: "",
      delta: nil,
      tone: completed.positive? ? "ok" : "neutral",
      spark: @filter.series(@period.series(triages.where(status: "completed"), :completed_at)),
      source: "live"
    }
  end

  def kpi_active
    active = conversations
               .where(state: %w[awaiting_consent consented])
               .where(updated_at: 1.hour.ago..)
               .count
    {
      id: "active",
      label: "Conversas ativas agora",
      value: @filter.count(active),
      unit: "",
      delta: nil,
      tone: "info",
      spark: @filter.series(@period.series(conversations, :updated_at)),
      source: "live"
    }
  end

  def kpi_urgent
    urgent = triages.where(status: "completed", priority: ..Protocols::Urgency.max_priority)
    count = urgent.where(completed_at: @period.from..@period.to).count
    {
      id: "urgent",
      label: "Casos urgentes",
      value: @filter.count(count),
      unit: "",
      delta: nil,
      tone: count.positive? ? "warn" : "ok",
      spark: @filter.series(@period.series(urgent, :completed_at)),
      source: "live"
    }
  end

  def kpi_completion
    base = triages.where(created_at: @period.from..@period.to)
    started = base.count
    completed = base.where(status: "completed").count
    rate = started.zero? ? 0.0 : (completed.to_f / started * 100).round(1)
    value = @filter.over(started, rate)
    {
      id: "completion",
      label: "Taxa de conclusão",
      value: value,
      unit: "%",
      delta: nil,
      tone: value.is_a?(Hash) ? "neutral" : (rate >= 70 ? "ok" : (rate >= 40 ? "warn" : "down")),
      spark: [],
      source: "live"
    }
  end

  # Infraestrutura — o Solid Queue mora no banco da cidade desde o Plano 5:
  # este número é só desta cidade (city_connection_queue_spec). Não é do
  # cidadão: ignora o filtro de bairro.
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
