# GET /admin/api/overview — KPIs operacionais (§4.0).
#
# Todos os KPIs agregam ao vivo no banco da cidade (ADR 0022; source: live).
# O campo source continua no contrato (§7) para quando um KPI passar a ler
# projeção por ADR novo. Urgência = régua do alerta (Protocols::Urgency).
#
# Filtro de bairro (ADR 0023): triagens pelo bairro copiado, conversas pelo
# bairro atual do cidadão; com o filtro ligado, 1 a 4 sai suprimido. Jobs com
# falha não são do cidadão: ignoram o filtro. kpi_completion usa
# @filter.share(completed, started, rate), não @filter.over(started, rate):
# com started visível, a taxa sozinha devolveria o completed suprimido por
# subtração (mesmo ajuste de Admin::TriagesQuery#completionRate e
# Admin::ConversationsQuery#abandonRate).
#
# Revogada (api#34; Triage.revoked, a definição do Analytics) não entra em
# concluídas, urgentes nem na taxa; sai à parte em `revoked`, só a contagem
# das iniciadas no período (mesmo recorte do Analytics), e só sem filtro de
# bairro (com ele, null).
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
      ],
      # Revogadas: recortadas por created_at (iniciadas no período, como o
      # Analytics), enquanto as concluídas são por completed_at — a triagem
      # iniciada antes do período e revogada dentro dele não aparece aqui.
      # Sem número com o filtro de bairro ligado (NeighborhoodFilter#unfiltered).
      revoked: @filter.unfiltered { triages.revoked.where(created_at: @period.from..@period.to).count }
    }
  end

  private

  def triages = @filter.triages(Triage.all)
  def conversations = @filter.conversations(Conversation.all)

  def kpi_done
    completed = triages
                  .counted_completed.where(completed_at: @period.from..@period.to)
                  .count
    {
      id: "done",
      label: "Triagens concluídas",
      value: @filter.count(completed),
      unit: "",
      delta: nil,
      tone: completed.positive? ? "ok" : "neutral",
      spark: @filter.series(@period.series(triages.counted_completed, :completed_at)),
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
    urgent = triages.counted_completed.where(priority: ..Protocols::Urgency.max_priority)
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
    completed = base.counted_completed.count
    rate = started.zero? ? 0.0 : (completed.to_f / started * 100).round(1)
    value = @filter.share(completed, started, rate)
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
