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
      parts = denominator.flat_map { |dim| periods.map { |period| by_dim.fetch(dim, {}).fetch(period, 0) } } +
              denominator.map { |dim| sum_all(by_dim, [ dim ]) }
      Suppression.group_rate(sum_all(by_dim, numerator), sum_all(by_dim, denominator), parts)
    end

    def sum_at(by_dim, dims, period) = dims.sum { |dim| by_dim.fetch(dim, {}).fetch(period, 0) }

    def sum_all(by_dim, dims) = dims.sum { |dim| by_dim.fetch(dim, {}).values.sum }

    def by_unit
      return [] if periods.empty?

      wait = totals("attendance.wait", keys: %i[health_unit_id dim], filters: UNIT)
      appointments = totals("appointment.ended", keys: %i[health_unit_id dim], filters: UNIT)
      outcomes = totals("attendance.closed", keys: %i[health_unit_id dim], filters: UNIT)
      ids = (wait.keys + appointments.keys + outcomes.keys).map(&:first).uniq
      names = unit_names(ids)
      rows = ids.map do |id|
        at = ->(source, dims) { dims.sum { |dim| source.fetch([ id, dim ], 0) } }
        rate = lambda do |source, numerator, denominator|
          Suppression.group_rate(at.call(source, numerator), at.call(source, denominator),
                                 denominator.map { |dim| source.fetch([ id, dim ], 0) })
        end
        { health_unit_id: id, name: names.fetch(id, id), attendances: Suppression.cell(at.call(outcomes, OUTCOMES)),
          wait_within_30_pct: rate.call(wait, WITHIN_30, AnalyticsDailyFact::WAIT_BUCKETS),
          no_show_pct: rate.call(appointments, %w[no_show], SHOWN),
          left_pct: rate.call(outcomes, %w[left], OUTCOMES) }
      end
      rows.sort_by { |row| [ -Suppression.sort_value(row[:attendances]), row[:name].to_s ] }
    end
  end
end
