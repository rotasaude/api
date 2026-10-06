# Intervalo de datas da cidade, inclusivo (contratos §9). Sem `from`, hoje; sem
# `to`, from + (default_days − 1). nil quando inválido ou longo demais.
module Scheduling
  module DateRange
    module_function

    def parse(from, to, default_days:, max_days:)
      first = from.present? ? Date.iso8601(from.to_s) : Time.zone.today
      last = to.present? ? Date.iso8601(to.to_s) : first + (default_days - 1)
      return nil if last < first || (last - first).to_i >= max_days

      first..last
    rescue ArgumentError, Date::Error
      nil
    end
  end
end
