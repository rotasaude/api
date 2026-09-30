module Analytics
  # GET /city_analytics (contratos §2): cidades ativas × semanas × os seis
  # indicadores, só do banco de plataforma — nunca abre banco de cidade (ADR
  # 0025, invariante). Célula: número (contagem inteira ou % com 1 casa),
  # { suppressed: true } ou null (sem linha = sem dado).
  class CityIndicatorsQuery
    DEFAULT_WEEKS = 12
    MAX_WEEKS = 104

    def self.call(from: nil, to: nil, today: Time.zone.today) = new(weeks(from, to, today)).call

    # Sem from/to: as 12 semanas que terminam na anterior à atual.
    def self.weeks(from, to, today)
      if from.blank? && to.blank?
        last = today.beginning_of_week - 7
        first = last - (DEFAULT_WEEKS - 1) * 7
      else
        first = parse(from).beginning_of_week
        last = parse(to).beginning_of_week
      end
      raise Params::Invalid, "invalid_range" if first > last || ((last - first).to_i / 7) + 1 > MAX_WEEKS

      (first..last).step(7).to_a
    end

    def self.parse(value)
      raise Params::Invalid, "invalid_range" unless value.is_a?(String) && value.match?(Params::DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      raise Params::Invalid, "invalid_range"
    end

    def initialize(weeks)
      @weeks = weeks
    end

    def call
      cities = City.where(status: "active").order(:name).to_a
      ids = cities.map(&:id)
      index = CityAnalyticsIndicator.where(city_id: ids, week_start: @weeks).index_by { |row| [ row.city_id, row.week_start, row.indicator ] }
      published = CityAnalyticsIndicator.where(city_id: ids).group(:city_id).maximum(:published_at)
      {
        weeks: @weeks.map(&:iso8601),
        indicators: CityAnalyticsIndicator::INDICATORS,
        cities: cities.map do |city|
          { id: city.id, slug: city.slug, name: city.name, uf: city.uf,
            last_published_at: published[city.id]&.utc&.iso8601,
            values: CityAnalyticsIndicator::INDICATORS.to_h do |indicator|
              [ indicator, @weeks.map { |week| cell(index[[ city.id, week, indicator ]]) } ]
            end }
        end
      }
    end

    private

    # decimal vira número JSON (BigDecimal sairia como string).
    def cell(row)
      return nil if row.nil?
      return Suppression::SUPPRESSED if row.suppressed

      CityAnalyticsIndicator::COUNT_INDICATORS.include?(row.indicator) ? row.value.to_i : row.value.to_f.round(1)
    end
  end
end
