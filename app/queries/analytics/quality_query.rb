module Analytics
  # Qualidade operacional (contratos §1.2). Taxa: numerador e denominador
  # somados no período (ou na unidade) e só então a regra de supressão; e
  # oculta se qualquer parte (faixa, estado, desfecho) for oculta (total do
  # grupo, contratos §0). O denominador de cada taxa contém o numerador.
  class QualityQuery < BaseQuery
    UNIT = %i[unit].freeze
    APPOINTMENT_STATUSES = %w[checked_in no_show expired cancelled_by_citizen].freeze
    OUTCOMES = %w[discharged referred return left].freeze
    WITHIN_30 = %w[0-15 15-30].freeze
    SHOWN = %w[checked_in no_show].freeze

    def call
      wait = split(sums("attendance.wait", keys: [ :dim ], filters: UNIT))
      appointments = split(sums("appointment.ended", keys: [ :dim ], filters: UNIT))
      outcomes = split(sums("attendance.closed", keys: [ :dim ], filters: UNIT))
      buckets = AnalyticsDailyFact::WAIT_BUCKETS
      {
        wait: {
          buckets: buckets.map { |bucket| { bucket: bucket, **row(wait.fetch(bucket, {})) } },
          within_30_pct: rate_series(wait, WITHIN_30, buckets),
          within_30_pct_total: rate_total(wait, WITHIN_30, buckets)
        },
        appointments: APPOINTMENT_STATUSES.map { |status| { status: status, **row(appointments.fetch(status, {})) } },
        no_show_pct: rate_series(appointments, %w[no_show], SHOWN),
        no_show_pct_total: rate_total(appointments, %w[no_show], SHOWN),
        attendance_outcomes: OUTCOMES.map { |outcome| { outcome: outcome, **row(outcomes.fetch(outcome, {})) } },
        left_pct: rate_series(outcomes, %w[left], OUTCOMES),
        left_pct_total: rate_total(outcomes, %w[left], OUTCOMES),
        by_unit: by_unit,
        units: units
      }
    end

    private

    def rate_series(by_dim, numerator, denominator)
      periods.map do |period|
        Suppression.group_rate(sum_at(by_dim, numerator, period), sum_at(by_dim, denominator, period),
                               denominator.map { |dim| by_dim.fetch(dim, {}).fetch(period, 0) })
      end
    end

    # Partes do total: cada célula da série e o total de cada linha.
    def rate_total(by_dim, numerator, denominator)
      Suppression.group_rate(sum_all(by_dim, numerator), sum_all(by_dim, denominator), parts(by_dim, denominator))
    end

    def parts(by_dim, dims)
      dims.flat_map { |dim| periods.map { |period| by_dim.fetch(dim, {}).fetch(period, 0) } } +
        dims.map { |dim| sum_all(by_dim, [ dim ]) }
    end

    # sums com chaves [health_unit_id, dim] → { unidade => { dim => { período => soma } } }.
    def by_unit_dim(sums)
      sums.each_with_object({}) do |((period, id, dim), value), acc|
        cells = ((acc[id] ||= {})[dim] ||= Hash.new(0))
        cells[period] += value
      end
    end

    def sum_at(by_dim, dims, period) = dims.sum { |dim| by_dim.fetch(dim, {}).fetch(period, 0) }

    def sum_all(by_dim, dims) = dims.sum { |dim| by_dim.fetch(dim, {}).values.sum }

    # Partes de cada taxa (e de attendances) da unidade: a célula de cada
    # período e o total de cada linha — com o recorte da unidade, é isso que
    # sai em buckets/appointments/attendance_outcomes (total do grupo, §0).
    def by_unit
      return [] if periods.empty?

      keys = %i[health_unit_id dim]
      wait = by_unit_dim(sums("attendance.wait", keys: keys, filters: UNIT))
      appointments = by_unit_dim(sums("appointment.ended", keys: keys, filters: UNIT))
      outcomes = by_unit_dim(sums("attendance.closed", keys: keys, filters: UNIT))
      ids = (wait.keys + appointments.keys + outcomes.keys).uniq
      names = unit_names(ids)
      rows = ids.map do |id|
        unit = ->(source) { source.fetch(id, {}) }
        # attendances é o total dos desfechos da unidade: com o recorte dela,
        # esses desfechos saem na mesma resposta (total do grupo, contratos §0).
        attendances = Suppression.group(sum_all(unit.call(outcomes), OUTCOMES), parts(unit.call(outcomes), OUTCOMES))
        { health_unit_id: id, name: names.fetch(id, id), attendances: attendances,
          wait_within_30_pct: rate_total(unit.call(wait), WITHIN_30, AnalyticsDailyFact::WAIT_BUCKETS),
          no_show_pct: rate_total(unit.call(appointments), %w[no_show], SHOWN),
          left_pct: rate_total(unit.call(outcomes), %w[left], OUTCOMES) }
      end
      rows.sort_by { |row| [ -Suppression.sort_value(row[:attendances]), row[:name].to_s ] }
    end
  end
end
