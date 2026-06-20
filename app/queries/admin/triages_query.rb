# GET /admin/api/triages — visão de triagens (§4.4).
#
# Reduzimos a referências e contagens. NUNCA expomos `answers` (LGPD).
# Versão do protocolo vem de protocol_definitions.
class Admin::TriagesQuery
  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @muni = municipality
    @period = period
  end

  def call
    base = Admin::Scoped.triages(@muni).where(created_at: @period.from..@period.to)
    started = base.count
    completed = base.where(status: "completed").count

    {
      series: @period.series(Admin::Scoped.triages(@muni), :created_at),
      started: started,
      completed: completed,
      completionRate: started.zero? ? 0.0 : (completed.to_f / started * 100).round(1),
      byProtocol: by_protocol(base, started)
    }
  end

  private

  def by_protocol(scope, total)
    rows = scope
             .joins(:protocol_definition)
             .group("protocol_definitions.name", "protocol_definitions.version", "protocol_definitions.status")
             .count
    rows.map do |(name, version, status), count|
      {
        version: "#{name} · #{version}",
        count: count,
        share: total.zero? ? 0 : (count.to_f / total * 100).round,
        status: status
      }
    end.sort_by { |row| -row[:count] }
  end
end
