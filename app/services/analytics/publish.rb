# app/services/analytics/publish.rb
module Analytics
  # Conjunto fixo da plataforma (spec §5; ADR 0025): seis indicadores
  # semanais da cidade inteira, já suprimidos. Refaz as semanas tocadas pela
  # janela apagando e gravando numa transação da plataforma (desvio 7 do
  # plano): idempotente, e a taxa que passou a "sem dado" some. O suprimido
  # vai como value NULL — o número de 1 a 4 nunca sai do banco da cidade.
  # Só semana fechada (segunda + 6 ≤ ontem; decisão de 2026-09-30): a semana
  # corrente é apagada se já estava lá e nunca é gravada.
  class Publish
    METRICS = %w[triage.started triage.completed attendance.closed attendance.wait appointment.ended].freeze
    RETENTION = 5.years

    def self.call(from:, to:, at: Time.current) = new(from: from, to: to, at: at).call

    def initialize(from:, to:, at:)
      @weeks = (from.beginning_of_week..to.beginning_of_week).step(7).to_a
      yesterday = Time.zone.yesterday
      @closed = @weeks.select { |week| week + 6 <= yesterday }
      @at = at
    end

    def call
      city = City.find_by!(slug: Current.city.slug)
      rows = @closed.flat_map { |week| indicators(week).map { |name, value| row(city, week, name, value) } }
      PlatformRecord.transaction(requires_new: true) do
        CityAnalyticsIndicator.where(city_id: city.id, week_start: @weeks).delete_all
        CityAnalyticsIndicator.insert_all!(rows) if rows.any?
        CityAnalyticsIndicator.where(city_id: city.id).where(week_start: ...(Time.zone.today - RETENTION)).delete_all
      end
      rows.size
    end

    private

    # { [semana, métrica, dim] => soma } das semanas inteiras (segunda a domingo).
    def sums
      @sums ||= AnalyticsDailyFact.where(metric: METRICS, day: @weeks.first..(@weeks.last + 6))
                                  .group(Arel.sql("date_trunc('week', day)::date"), :metric, :dim).sum(:value)
                                  .each_with_object(Hash.new(0)) do |((week, metric, dim), value), acc|
                                    acc[[ Analytics.to_date(week), metric, dim ]] += value
                                  end
    end

    def total(week, metric, dims = nil)
      sums.sum { |(w, m, d), value| w == week && m == metric && (dims.nil? || dims.include?(d)) ? value : 0 }
    end

    # nil (taxa sem denominador) = nenhuma linha naquela semana.
    def indicators(week)
      closed = total(week, "attendance.closed")
      {
        "triages_started" => Suppression.cell(total(week, "triage.started")),
        "triages_completed" => Suppression.cell(total(week, "triage.completed")),
        "attendances_closed" => Suppression.cell(closed),
        "wait_within_30_pct" => Suppression.rate(total(week, "attendance.wait", %w[0-15 15-30]),
                                                 total(week, "attendance.wait")),
        "no_show_pct" => Suppression.rate(total(week, "appointment.ended", %w[no_show]),
                                          total(week, "appointment.ended", %w[checked_in no_show])),
        "left_pct" => Suppression.rate(total(week, "attendance.closed", %w[left]), closed)
      }.compact
    end

    def row(city, week, indicator, value)
      suppressed = value == Suppression::SUPPRESSED
      { city_id: city.id, week_start: week, indicator: indicator, value: suppressed ? nil : value,
        suppressed: suppressed, published_at: @at }
    end
  end
end
