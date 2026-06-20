# GET /admin/api/classification — distribuição de tier/priority/mode (§4.5).
#
# Lê do snapshot congelado (outcome jsonb em Triagem). Sem recompute (ADR 0007).
# `byMode` extrai outcome->scoring->mode quando presente; vazio em caso contrário.
class Admin::ClassificationQuery
  TIERS = %w[low medium high].freeze
  TONES = { "low" => "ok", "medium" => "warn", "high" => "down" }.freeze

  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    base = Admin::Scoped.triages(@muni)
             .where(status: "completed", completed_at: @period.from..@period.to)

    {
      tiers: tier_counts(base),
      byProtocol: by_protocol(base),
      priorityTrue: base.where(priority: true).count,
      priorityTrend: @period.series(Admin::Scoped.triages(@muni).where(priority: true), :completed_at),
      byMode: by_mode(base),
      sampleTriages: sample(base.limit(8))
    }
  end

  private

  def tier_counts(scope)
    counts = scope.group(:tier).count
    TIERS.map do |t|
      { key: t, label: t, count: counts[t] || 0, tone: TONES[t] }
    end
  end

  def by_protocol(scope)
    rows = scope
             .joins(:protocol_definition)
             .group("protocol_definitions.name", "protocol_definitions.version", :tier)
             .count
    pivot = Hash.new { |h, k| h[k] = { protocol: k, low: 0, medium: 0, high: 0 } }
    rows.each do |(name, version, tier), count|
      key = "#{name} · #{version}"
      next unless TIERS.include?(tier)
      pivot[key][:protocol] = key
      pivot[key][tier.to_sym] = count
    end
    pivot.values
  end

  # outcome é jsonb. Extrai scoring.mode via -> operators.
  def by_mode(scope)
    rows = scope
             .where("outcome ? 'scoring'")
             .group(Arel.sql("outcome -> 'scoring' ->> 'mode'"))
             .count
    total = rows.values.sum
    rows.map do |mode, count|
      {
        mode: mode,
        label: mode,
        count: count,
        share: total.zero? ? 0 : (count.to_f / total * 100).round
      }
    end
  end

  # Amostra: só referências. NUNCA payload de answers.
  def sample(scope)
    scope.order(completed_at: :desc).map do |t|
      {
        id: t.id,
        tier: t.tier,
        priority: t.priority,
        mode: t.outcome&.dig("scoring", "mode"),
        protocol: "#{t.protocol_name} · #{t.protocol_definition&.version}",
        at: t.completed_at&.strftime("%H:%M")
      }
    end
  end
end
