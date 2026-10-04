# GET /admin/api/classification — distribuição de tier/urgência/modo (§4.5; F-05.9).
#
# Lê as triagens concluídas no período, ao vivo (ADR 0022). O tier é vocabulário
# livre de cada protocolo (ex.: baixa/alta, indefinido), então a lista de tiers
# sai dos dados, do mais urgente para o menos urgente. A urgência usa a mesma
# régua do alerta (Protocols::Urgency: priority <= URGENT_MAX_PRIORITY). O modo
# de scoring é o da versão do protocolo em que cada triagem terminou.
#
# Expand/contract (ADR 0015): priorityTrue/priorityTrend e as chaves
# low/medium/high do pivô ficam como apelidos do contrato antigo enquanto o
# console do operador (apps/admin) não migra para urgent/urgentTrend/counts.
#
# Filtro de bairro (ADR 0023): triagens pelo bairro copiado; com o filtro
# ligado, contagens de 1 a 4 (e o share delas) saem suprimidas, e a amostra
# vem null quando o total filtrado é de 1 a 4 OU quando qualquer contagem do
# painel (tier, protocolo, urgência, modo, incluindo QUALQUER ponto de
# urgentTrend, seja hora ou dia) sai suprimida — a amostra lista cada
# triagem com o tier dela, então uma categoria suprimida apareceria de
# novo, sem disfarce, na mesma resposta.
#
# Revogada (api#34; Triage.revoked, a definição do Analytics) fica fora de
# tiers, urgência, pivôs e amostra; sai à parte em `revoked`, só a contagem
# das iniciadas no período, suprimida pelo filtro. Nunca linha de revogada.
class Admin::ClassificationQuery
  LEGACY_TIERS = %w[low medium high].freeze
  MODE_SQL = "protocol_definitions.definition -> 'scoring' ->> 'type'".freeze

  def self.call(period:, filter: Admin::NeighborhoodFilter.off)
    new(period, filter).call
  end

  def initialize(period, filter)
    @period = period
    @filter = filter
  end

  def call
    triages = @filter.triages(Triage.all)
    base = triages.counted_completed.where(completed_at: @period.from..@period.to)
    total = base.count
    urgent_max = Protocols::Urgency.max_priority
    tiers = tier_counts(base, urgent_max)
    urgent = @filter.count(base.where(priority: ..urgent_max).count)
    urgent_trend = @filter.series(@period.series(triages.counted_completed.where(priority: ..urgent_max), :completed_at))
    protocol_rows = by_protocol(base)
    mode_rows = by_mode(base)
    sample_rows = sample(base.limit(8), urgent_max)
    listed = @filter.list(total, sample_rows)
    listed = nil if suppressed_anywhere?(tiers) || suppressed_anywhere?(urgent) ||
      suppressed_anywhere?(urgent_trend) || suppressed_anywhere?(protocol_rows) || suppressed_anywhere?(mode_rows)

    {
      tiers: tiers,
      tierKeys: tiers.map { |t| t[:key] },
      urgent: urgent,
      urgentMaxPriority: urgent_max,
      urgentTrend: urgent_trend,
      priorityTrue: urgent,        # apelido (apps/admin)
      priorityTrend: urgent_trend, # apelido (apps/admin)
      byProtocol: protocol_rows,
      byMode: mode_rows,
      sampleTriages: listed,
      revoked: @filter.count(triages.revoked.where(created_at: @period.from..@period.to).count)
    }
  end

  private

  # A amostra some se algum número do painel (tier, protocolo, urgência ou
  # modo) saiu suprimido — não só se o total saiu.
  def suppressed_anywhere?(node)
    case node
    when Hash
      return true if node == Admin::SmallCount::SUPPRESSED
      node.values.any? { |v| suppressed_anywhere?(v) }
    when Array
      node.any? { |v| suppressed_anywhere?(v) }
    else
      false
    end
  end

  # Ordena pela prioridade mais urgente que o tier recebeu no período (menor
  # primeiro); tier sem priority vai para o fim.
  def tier_counts(scope, urgent_max)
    rows = scope.group(:tier).pluck(:tier, Arel.sql("COUNT(*)"), Arel.sql("MIN(priority)"))
    rows.sort_by { |tier, _count, min_priority| [ min_priority || Float::INFINITY, tier.to_s ] }.map do |tier, count, min_priority|
      key = tier || "sem tier"
      { key: key, label: key, count: @filter.count(count), tone: tone(min_priority, urgent_max) }
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
    end.values.map do |row|
      legacy = LEGACY_TIERS.to_h { |t| [ t.to_sym, @filter.count(row[:counts][t] || 0) ] } # apelidos (apps/admin)
      row.merge(counts: row[:counts].transform_values { |c| @filter.count(c) }).merge(legacy)
    end
  end

  def by_mode(scope)
    rows = scope.joins(:protocol_definition).group(Arel.sql(MODE_SQL)).count
    total = rows.values.sum
    rows.map do |mode, count|
      share = total.zero? ? 0 : (count.to_f / total * 100).round
      {
        mode: mode,
        label: mode,
        count: @filter.count(count),
        share: @filter.share(count, total, share)
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
