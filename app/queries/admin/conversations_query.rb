# GET /admin/api/conversations — FSM e funil (§4.2; F-02.9).
#
# Conta as conversas da cidade, de qualquer canal (a web é o canal do cidadão,
# ADR 0017), iniciadas no período: o funil mostra os estados ativos e as
# saídas mostram cada desfecho terminal. abandonRate = abandonadas ÷ iniciadas
# no período, em %.
#
# Filtro de bairro (ADR 0023): conversa pelo bairro ATUAL do cidadão (none
# inclui conversa sem cidadão); tempo médio pelo bairro copiado na triagem.
# Com o filtro ligado, 1 a 4 sai suprimido (e taxa/média sobre eles).
# abandonRate usa @filter.share(abandoned, started, rate) — não @filter.over
# (started, rate) — pelo mesmo motivo de TriagesQuery#completionRate: com
# started visível, a taxa sozinha devolveria o abandoned suprimido por
# subtração. avgToCompleteMin continua em @filter.over(total, ...): ali
# `total` já É a própria contagem descrita (nº de triagens concluídas usadas
# na média), não uma razão entre duas contagens diferentes.
class Admin::ConversationsQuery
  EXITS = { "completed" => "ok", "abandoned" => "warn", "declined" => "neutral",
            "cancelled" => "neutral", "revoked" => "warn" }.freeze

  def self.call(period:, filter: Admin::NeighborhoodFilter.off)
    new(period, filter).call
  end

  def initialize(period, filter)
    @period = period
    @filter = filter
  end

  def call
    base = @filter.conversations(Conversation.all)
    in_period = base.where(created_at: @period.from..@period.to)

    state_counts = in_period.group(:state).count
    {
      live: @filter.count(base.where(state: %w[awaiting_consent consented]).count),
      funnel: [
        { key: "greeting",         label: "greeting",         count: @filter.count(state_counts["greeting"]         || 0), tone: "neutral" },
        { key: "awaiting_consent", label: "awaiting_consent", count: @filter.count(state_counts["awaiting_consent"] || 0), tone: "info" },
        { key: "consented",        label: "consented",        count: @filter.count(state_counts["consented"]        || 0), tone: "ok" }
      ],
      exits: EXITS.map { |key, tone| { key: key, label: key, count: @filter.count(state_counts[key] || 0), tone: tone } },
      abandonRate: abandon_rate(state_counts),
      avgToCompleteMin: avg_complete_minutes,
      liveActive: {
        awaiting: @filter.count(base.where(state: "awaiting_consent").count),
        inProgress: @filter.count(base.where(state: "consented").count)
      }
    }
  end

  private

  def abandon_rate(state_counts)
    started = state_counts.values.sum
    return nil if started.zero?
    abandoned = state_counts["abandoned"] || 0
    @filter.share(abandoned, started, (abandoned.to_f / started * 100).round(1))
  end

  def avg_complete_minutes
    completed = @filter.triages(Triage.all)
                  .where(status: "completed", completed_at: @period.from..@period.to)
    total = completed.count
    return nil if total.zero?
    seconds = completed
                .where.not(completed_at: nil)
                .pluck(Arel.sql("EXTRACT(EPOCH FROM (triages.completed_at - triages.created_at))"))
                .compact
    return nil if seconds.empty?
    @filter.over(total, (seconds.sum / seconds.size / 60.0).round(1))
  end
end
