module Analytics
  # Calibração de protocolo (contratos §1.3): período inteiro, sem série. Por
  # versão porque o tier é texto de cada protocolo (D13).
  class CalibrationQuery < BaseQuery
    OUTCOMES = %w[discharged referred return left none].freeze
    FILTERS = %i[protocol version].freeze

    def call
      facts = totals("calibration.outcome", keys: %i[protocol_name protocol_version tier dim], filters: FILTERS)
      versions = facts.group_by { |(name, version, _tier, _dim), _value| [ name, version ] }
      {
        versions: versions.sort_by { |(name, version), _| [ name.to_s, -version.to_i ] }.map do |(name, version), entries|
          by_tier = entries.group_by { |(_name, _version, tier, _dim), _value| tier }
          rows = by_tier.map do |tier, cells|
            tier_row(tier, cells.to_h { |(_name, _version, _tier, dim), value| [ dim, value ] })
          end
          { protocol_name: name, protocol_version: version,
            rows: rows.sort_by { |row| [ -Suppression.sort_value(row[:total]), row[:tier].to_s ] } }
        end
      }
    end

    private

    # Total do grupo: um desfecho oculto esconde o total e todas as
    # proporções da linha (contratos §0).
    def tier_row(tier, by_outcome)
      counts = OUTCOMES.map { |outcome| by_outcome.fetch(outcome, 0) }
      total = counts.sum
      { tier: tier, total: Suppression.group(total, counts),
        outcomes: OUTCOMES.to_h { |outcome| [ outcome, Suppression.cell(by_outcome.fetch(outcome, 0)) ] },
        shares: OUTCOMES.to_h { |outcome| [ outcome, Suppression.group_rate(by_outcome.fetch(outcome, 0), total, counts) ] } }
    end
  end
end
