# GET /admin/api/conversations — FSM e funil (§4.2).
#
# Schema real: Conversation#state ∈ greeting | awaiting_consent | consented
#              | revoked. NÃO existe `completed`/`cancelled`/`abandoned`.
# O funil do brief é remapeado para esses estados; "exits" sai vazio até
# existir um sinal real (revoked é o único proxy).
class Admin::ConversationsQuery
  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    base = Admin::Scoped.conversations(@muni)
    in_period = base.where(created_at: @period.from..@period.to)

    state_counts = in_period.group(:state).count
    {
      live: base.where(state: %w[awaiting_consent consented]).count,
      funnel: [
        { key: "greeting",         label: "greeting",         count: state_counts["greeting"]         || 0, tone: "neutral" },
        { key: "awaiting_consent", label: "awaiting_consent", count: state_counts["awaiting_consent"] || 0, tone: "info" },
        { key: "consented",        label: "consented",        count: state_counts["consented"]        || 0, tone: "ok" }
      ],
      exits: [
        { key: "revoked", label: "revoked", count: state_counts["revoked"] || 0, tone: "warn" }
      ],
      abandonRate: nil,
      avgToCompleteMin: avg_complete_minutes,
      liveActive: {
        awaiting: base.where(state: "awaiting_consent").count,
        inProgress: base.where(state: "consented").count
      }
    }
  end

  private

  def avg_complete_minutes
    completed = Admin::Scoped.triages(@muni)
                  .where(status: "completed", completed_at: @period.from..@period.to)
    return nil if completed.count.zero?
    seconds = completed
                .where.not(completed_at: nil)
                .pluck(Arel.sql("EXTRACT(EPOCH FROM (completed_at - created_at))"))
                .compact
    return nil if seconds.empty?
    (seconds.sum / seconds.size / 60.0).round(1)
  end
end
