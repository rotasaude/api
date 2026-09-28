# GET /admin/api/triages — visão de triages (§4.4).
#
# Reduzimos a referências e contagens. NUNCA expomos `answers` (LGPD).
# Versão do protocolo vem de protocol_definitions.
#
# Filtro de bairro (ADR 0023): pelo bairro copiado na triagem; com o filtro
# ligado, 1 a 4 sai suprimido (e a taxa/share calculados sobre eles).
class Admin::TriagesQuery
  def self.call(period:, filter: Admin::NeighborhoodFilter.off)
    new(period, filter).call
  end

  def initialize(period, filter)
    @period = period
    @filter = filter
  end

  def call
    triages = @filter.triages(Triage.all)
    base = triages.where(created_at: @period.from..@period.to)
    started = base.count
    completed = base.where(status: "completed").count
    rate = started.zero? ? 0.0 : (completed.to_f / started * 100).round(1)

    {
      series: @filter.series(@period.series(triages, :created_at)),
      started: @filter.count(started),
      completed: @filter.count(completed),
      completionRate: @filter.over(started, rate),
      byProtocol: by_protocol(base, started)
    }
  end

  private

  def by_protocol(scope, total)
    rows = scope
             .joins(:protocol_definition)
             .group("protocol_definitions.name", "protocol_definitions.version", "protocol_definitions.status")
             .count
    rows.sort_by { |_key, count| -count }.map do |(name, version, status), count|
      share = total.zero? ? 0 : (count.to_f / total * 100).round
      {
        version: "#{name} · #{version}",
        count: @filter.count(count),
        share: @filter.share(count, total, share),
        status: status
      }
    end
  end
end
