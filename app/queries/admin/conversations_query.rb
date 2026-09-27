# GET /admin/api/conversations — FSM e funil (§4.2; F-02.9).
#
# Conta as conversas da cidade, de qualquer canal (a web é o canal do cidadão,
# ADR 0017), iniciadas no período: o funil mostra os estados ativos e as
# saídas mostram cada desfecho terminal. abandonRate = abandonadas ÷ iniciadas
# no período, em %.
class Admin::ConversationsQuery
  EXITS = { "completed" => "ok", "abandoned" => "warn", "declined" => "neutral",
            "cancelled" => "neutral", "revoked" => "warn" }.freeze

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    base = Conversation.all
    in_period = base.where(created_at: @period.from..@period.to)

    state_counts = in_period.group(:state).count
    {
      live: base.where(state: %w[awaiting_consent consented]).count,
      funnel: [
        { key: "greeting",         label: "greeting",         count: state_counts["greeting"]         || 0, tone: "neutral" },
        { key: "awaiting_consent", label: "awaiting_consent", count: state_counts["awaiting_consent"] || 0, tone: "info" },
        { key: "consented",        label: "consented",        count: state_counts["consented"]        || 0, tone: "ok" }
      ],
      exits: EXITS.map { |key, tone| { key: key, label: key, count: state_counts[key] || 0, tone: tone } },
      abandonRate: abandon_rate(state_counts),
      avgToCompleteMin: avg_complete_minutes,
      liveActive: {
        awaiting: base.where(state: "awaiting_consent").count,
        inProgress: base.where(state: "consented").count
      }
    }
  end

  private

  def abandon_rate(state_counts)
    started = state_counts.values.sum
    return nil if started.zero?
    ((state_counts["abandoned"] || 0).to_f / started * 100).round(1)
  end

  def avg_complete_minutes
    completed = Triage.all
                  .where(status: "completed", completed_at: @period.from..@period.to)
    return nil if completed.count.zero?
    seconds = completed
                .where.not(completed_at: nil)
                .pluck(Arel.sql("EXTRACT(EPOCH FROM (triages.completed_at - triages.created_at))"))
                .compact
    return nil if seconds.empty?
    (seconds.sum / seconds.size / 60.0).round(1)
  end
end
