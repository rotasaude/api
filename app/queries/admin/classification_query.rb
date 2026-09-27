# GET /admin/api/classification — distribuição de tier/urgência/modo (§4.5; F-05.9).
#
# Lê as triagens concluídas no período, ao vivo (ADR 0022). O tier é vocabulário
# livre de cada protocolo (ex.: baixa/alta, indefinido), então a lista de tiers
# sai dos dados, do mais urgente para o menos urgente. A urgência usa a mesma
# régua do alerta (Protocols::Urgency: priority <= URGENT_MAX_PRIORITY). O modo
# de scoring é o da versão do protocolo em que cada triagem terminou.
class Admin::ClassificationQuery
  MODE_SQL = "protocol_definitions.definition -> 'scoring' ->> 'type'".freeze

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    base = Triage.all
             .where(status: "completed", completed_at: @period.from..@period.to)
    urgent_max = Protocols::Urgency.max_priority
    tiers = tier_counts(base, urgent_max)

    {
      tiers: tiers,
      tierKeys: tiers.map { |t| t[:key] },
      urgent: base.where(priority: ..urgent_max).count,
      urgentMaxPriority: urgent_max,
      urgentTrend: @period.series(Triage.all.where(status: "completed", priority: ..urgent_max), :completed_at),
      byProtocol: by_protocol(base),
      byMode: by_mode(base),
      sampleTriages: sample(base.limit(8), urgent_max)
    }
  end

  private

  # Ordena pela prioridade mais urgente que o tier recebeu no período (menor
  # primeiro); tier sem priority vai para o fim.
  def tier_counts(scope, urgent_max)
    rows = scope.group(:tier).pluck(:tier, Arel.sql("COUNT(*)"), Arel.sql("MIN(priority)"))
    rows.sort_by { |tier, _count, min_priority| [ min_priority || Float::INFINITY, tier.to_s ] }.map do |tier, count, min_priority|
      key = tier || "sem tier"
      { key: key, label: key, count: count, tone: tone(min_priority, urgent_max) }
    end
  end

  def tone(min_priority, urgent_max)
    return "neutral" if min_priority.nil?
    min_priority <= urgent_max ? "down" : "info"
  end

  def by_protocol(scope)
    rows = scope
             .joins(:protocol_definition)
             .group("protocol_definitions.name", "protocol_definitions.version", :tier)
             .count
    rows.each_with_object({}) do |((name, version, tier), count), pivot|
      key = "#{name} · #{version}"
      pivot[key] ||= { protocol: key, counts: {} }
      pivot[key][:counts][tier || "sem tier"] = count
    end.values
  end

  def by_mode(scope)
    rows = scope.joins(:protocol_definition).group(Arel.sql(MODE_SQL)).count
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
  def sample(scope, urgent_max)
    scope.includes(:protocol_definition).order(completed_at: :desc).map do |t|
      {
        id: t.id,
        tier: t.tier,
        priority: t.priority,
        urgent: !t.priority.nil? && t.priority <= urgent_max,
        mode: t.protocol_definition&.definition&.dig("scoring", "type"),
        protocol: "#{t.protocol_name} · #{t.protocol_definition&.version}",
        at: t.completed_at&.strftime("%H:%M")
      }
    end
  end
end
