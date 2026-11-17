# Índices de ovitrampa (módulo 35a, ADR 0054; contrato §6; A-9), por bairro
# (o do quarteirão congelado na ovitrampa) e semana epidemiológica do MS
# (Surveillance::EpiWeek da instalação da palheta, gravada como inteiro
# YYYYWW; texto "YYYY-WW" fora do banco):
#   - examinadas = leituras ok e contadas; positivas = egg_count > 0; ovos =
#     soma das examinadas; lost e damaged = leituras com essa condição;
#   - IPO = positivas ÷ examinadas × 100; IDO = ovos ÷ positivas; IDV = ovos ÷
#     examinadas; uma casa decimal; sem examinadas → nil (o IDO também é nil
#     sem positivas: não há divisor).
# Uma linha por (bairro, semana) pedidos, na ordem dada, numa consulta só.
# Só contagens: nada de pessoa nem de ovitrampa.
module VectorControl
  module OvitrapIndex
    module_function

    # -> [{ neighborhood_id:, epi_week: "YYYY-WW", examined:, positive:, eggs:, ipo:, ido:, idv:, lost:, damaged: }]
    def for(neighborhood_ids:, epi_weeks:)
      weeks = epi_weeks.map { |week| epi_week(week) }
      rows = counts(neighborhood_ids, weeks.map { |week| column(week) })
      neighborhood_ids.product(weeks).map do |neighborhood_id, week|
        examined, positive, eggs, lost, damaged = rows.fetch([ neighborhood_id, column(week) ], [ 0, 0, 0, 0, 0 ])
        { neighborhood_id: neighborhood_id, epi_week: week.to_s, examined: examined, positive: positive, eggs: eggs,
          ipo: ratio(positive * 100, examined), ido: ratio(eggs, positive), idv: ratio(eggs, examined), lost: lost, damaged: damaged }
      end
    end

    # Inteiro YYYYWW da semana epidemiológica do dia (a coluna epi_week, A-9).
    def week_of(date) = column(Surveillance::EpiWeek.for(date))

    # "YYYY-WW" do inteiro YYYYWW gravado.
    def week_text(value) = Surveillance::EpiWeek.new(year: value / 100, week: value % 100).to_s

    def column(week) = week.year * 100 + week.week

    def epi_week(value)
      return value if value.is_a?(Surveillance::EpiWeek)

      Surveillance::EpiWeek.parse(value) || raise(ArgumentError, "epi_week")
    end

    def counts(neighborhood_ids, columns)
      return {} if neighborhood_ids.empty? || columns.empty?

      OvitrapReading.joins(ovitrap: :city_block)
                    .where(city_blocks: { neighborhood_id: neighborhood_ids }, epi_week: columns)
                    .group("city_blocks.neighborhood_id", "ovitrap_readings.epi_week")
                    .pluck("city_blocks.neighborhood_id", "ovitrap_readings.epi_week",
                           Arel.sql("COUNT(*) FILTER (WHERE ovitrap_readings.egg_count IS NOT NULL)"),
                           Arel.sql("COUNT(*) FILTER (WHERE ovitrap_readings.egg_count > 0)"),
                           Arel.sql("COALESCE(SUM(ovitrap_readings.egg_count), 0)"),
                           Arel.sql("COUNT(*) FILTER (WHERE ovitrap_readings.condition = 'lost')"),
                           Arel.sql("COUNT(*) FILTER (WHERE ovitrap_readings.condition = 'damaged')"))
                    .to_h { |neighborhood_id, column, *numbers| [ [ neighborhood_id, column ], numbers.map(&:to_i) ] }
    end

    def ratio(numerator, denominator)
      return nil if denominator.zero?

      Rational(numerator, denominator).round(1).to_f
    end
  end
end
