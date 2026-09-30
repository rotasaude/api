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
      tiers = split(sums("triage.completed", keys: [ :tier ], filters: TRIAGE))
      protocols = split(sums("triage.completed", keys: [ :protocol_name ], filters: TRIAGE))
      triages = { started: series(started), completed: completed_series(completed, tiers.values + protocols.values),
                  aborted: series(aborted) }
      by_tier = keyed_rows(tiers, :tier)
      by_protocol = keyed_rows(protocols, :protocol_name)
      by_neighborhood = ordered(neighborhood_rows, name: :name)
      # Total do grupo: qualquer célula de triages.* ou total de tier,
      # protocolo ou bairro oculto esconde os três totais do período.
      parts = triages.values.flatten + (by_tier + by_protocol + by_neighborhood).map { |row| row[:total] }
      {
        triages: triages,
        triages_total: { started: Suppression.group(started.values.sum, parts),
                         completed: Suppression.group(completed.values.sum, parts),
                         aborted: Suppression.group(aborted.values.sum, parts) },
        by_tier: by_tier,
        by_protocol: by_protocol,
        by_neighborhood: by_neighborhood,
        attendances_by_unit: ordered(unit_rows, name: :name),
        requests_opened: ordered(fixed_rows("request.opened", REQUEST_KINDS, :kind), name: :kind),
        requests_closed: ordered(fixed_rows("request.closed", CLOSED_REASONS, :reason), name: :reason),
        units: units
      }
    end

    private

    def keyed_rows(split_rows, column)
      ordered(split_rows.map { |key, by_period| { column => key, **row(by_period) } }, name: column)
    end

    # Célula de período do agregado: oculta se o tier ou o protocolo daquele
    # período (as partes exibidas na mesma resposta) for oculto.
    def completed_series(completed, parts)
      periods.map { |period| Suppression.group(completed.fetch(period, 0), parts.map { |part| part.fetch(period, 0) }) }
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
