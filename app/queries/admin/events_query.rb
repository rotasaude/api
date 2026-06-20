# GET /admin/api/events — auditoria via domain_events (§4.8).
#
# Payload é APENAS referência (ADR 0003/0009). Allowlist explícita:
# nada de campos livres do payload — só name/actor/ref/aggregate.
#
# GAP: domain_events não tem `municipality_id` (RECONCILE.md). Cross-tenant
# até existir coluna/projeção com escopo.
class Admin::EventsQuery
  RETENTION_MONTHS = 12

  def self.call(name:, from:, to:, period:)
    new(name, from, to, period).call
  end

  def initialize(name, from, to, period)
    @name_filter = name.presence
    @from = from.presence
    @to = to.presence
    @period = period
  end

  def call
    base = DomainEvent.all
    base = filter_name(base)
    base = base.where(occurred_at: window)

    {
      total: base.count,
      retentionMonths: RETENTION_MONTHS,
      replayAnchor: replay_anchor,
      byType: base.group(:name).count.map { |n, c| { name: n, count: c } },
      stream: stream(base.order(occurred_at: :desc).limit(50)),
      filters: %w[todos triage.* consent.* conversation.* protocol.* priority.*]
    }
  end

  private

  def filter_name(scope)
    return scope unless @name_filter
    if @name_filter.end_with?(".*")
      prefix = @name_filter.sub(".*", "")
      scope.where("name LIKE ?", "#{prefix}.%")
    else
      scope.where(name: @name_filter)
    end
  end

  def window
    return Time.parse(@from)..Time.parse(@to) if @from && @to
    @period.from..@period.to
  end

  def replay_anchor
    first = DomainEvent.order(:occurred_at).first
    return nil unless first
    {
      seq: "evt_id=#{first.id}",
      at: first.occurred_at.iso8601
    }
  end

  # ALLOWLIST: name + actor + ref + at + aggregate. NUNCA payload livre.
  def stream(scope)
    scope.map do |ev|
      {
        at: ev.occurred_at.iso8601,
        name: ev.name,
        actor: ev.payload&.dig("actor") || "sistema",
        ref: "#{ev.aggregate_type.underscore}_id=#{ev.aggregate_id}",
        muni: nil
      }
    end
  end
end
