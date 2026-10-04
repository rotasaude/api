# GET /admin/api/triages — visão de triages (§4.4).
#
# Reduzimos a referências e contagens. NUNCA expomos `answers` (LGPD).
# Versão do protocolo vem de protocol_definitions.
#
# Filtro de bairro (ADR 0023): pelo bairro copiado na triagem; com o filtro
# ligado, 1 a 4 sai suprimido (e a taxa/share calculados sobre eles).
# completionRate usa @filter.share(completed, started, rate), não @filter.over
# (started, rate): com started visível e completed suprimido, a taxa sozinha
# devolveria o completed por subtração (ex.: 6 iniciadas, 33.3% = 2
# concluídas) — share suprime quando QUALQUER um dos dois lados é pequeno.
#
# Revogada (api#34; Triage.revoked, a definição do Analytics) segue em
# iniciadas, mas não entra em concluídas nem na taxa; sai à parte em
# `revoked`, só a contagem das iniciadas no período, suprimida pelo filtro.
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
    completed = base.counted_completed.count
    rate = started.zero? ? 0.0 : (completed.to_f / started * 100).round(1)

    {
      series: @filter.series(@period.series(triages, :created_at)),
      started: @filter.count(started),
      completed: @filter.count(completed),
      completionRate: @filter.share(completed, started, rate),
      byProtocol: by_protocol(base, started),
      revoked: @filter.count(base.revoked.count)
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
