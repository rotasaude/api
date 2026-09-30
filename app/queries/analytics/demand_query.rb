# app/queries/analytics/demand_query.rb
module Analytics
  # Demanda por território (contratos §1.1). Bairro e protocolo recortam só
  # as métricas de triagem; unidade, só chegadas e pedidos.
  class DemandQuery < BaseQuery
    TRIAGE = %i[neighborhood protocol].freeze
    UNIT = %i[unit].freeze
    REQUEST_KINDS = %w[return referral].freeze
    CLOSED_REASONS = %w[fulfilled citizen_cancelled dismissed].freeze
    NO_NEIGHBORHOOD = "Sem bairro"

    def call
      started = flat(sums("triage.started", filters: TRIAGE))
      completed = flat(sums("triage.completed", filters: TRIAGE))
      aborted = flat(sums("triage.aborted", filters: TRIAGE))
      {
        triages: { started: series(started), completed: series(completed), aborted: series(aborted) },
        triages_total: { started: Suppression.cell(started.values.sum), completed: Suppression.cell(completed.values.sum),
                         aborted: Suppression.cell(aborted.values.sum) },
        by_tier: keyed_rows("triage.completed", :tier),
        by_protocol: keyed_rows("triage.completed", :protocol_name),
        by_neighborhood: ordered(neighborhood_rows, name: :name),
        attendances_by_unit: ordered(unit_rows, name: :name),
        requests_opened: ordered(fixed_rows("request.opened", REQUEST_KINDS, :kind), name: :kind),
        requests_closed: ordered(fixed_rows("request.closed", CLOSED_REASONS, :reason), name: :reason),
        units: units
      }
    end

    private

    def keyed_rows(metric, column)
      rows = split(sums(metric, keys: [ column ], filters: TRIAGE)).map { |key, by_period| { column => key, **row(by_period) } }
      ordered(rows, name: column)
    end

    def neighborhood_rows
      by_neighborhood = split(sums("triage.completed", keys: [ :neighborhood_id ], filters: TRIAGE))
      names = Neighborhood.where(id: by_neighborhood.keys.compact).pluck(:id, :name).to_h
      by_neighborhood.map do |id, by_period|
        { neighborhood_id: id, name: id ? names.fetch(id, id) : NO_NEIGHBORHOOD,
          total: Suppression.cell(by_period.values.sum) }
      end
    end

    def unit_rows
      by_unit = split(sums("attendance.checked_in", keys: [ :health_unit_id ], filters: UNIT))
      names = unit_names(by_unit.keys)
      by_unit.map { |id, by_period| { health_unit_id: id, name: names.fetch(id, id), **row(by_period) } }
    end

    def fixed_rows(metric, values, name)
      by_dim = split(sums(metric, keys: [ :dim ], filters: UNIT))
      values.map { |value| { name => value, **row(by_dim.fetch(value, {})) } }
    end
  end
end
