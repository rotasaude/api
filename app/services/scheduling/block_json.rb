# Faixas efetivas (Availability::Block, instantes) na forma do modelo (contratos
# §2, §9, §10): `HH:MM` no fuso da cidade, recortadas pelo dia local. O recorte
# que chega à meia-noite termina em "24:00" (só na saída). `bookable` traz o
# nome do tipo e o `slot_minutes` quando veio do modelo.
module Scheduling
  module BlockJson
    module_function

    # Uma entrada por dia local que cada faixa cobre.
    def list(blocks, zone:, catalog:)
      blocks.flat_map do |block|
        first = block.starts_at.in_time_zone(zone).to_date
        last = (block.ends_at - 1.second).in_time_zone(zone).to_date
        (first..last).filter_map { |day| piece(block, day: day, zone: zone, catalog: catalog) }
      end
    end

    # Só o pedaço de cada faixa que cai no dia local `day` (agendas do dia).
    def for_day(blocks, day:, zone:, catalog:)
      blocks.filter_map { |block| piece(block, day: day, zone: zone, catalog: catalog) }
    end

    # O pedaço da faixa que cai no dia local `day`, ou nil.
    def piece(block, day:, zone:, catalog:)
      day_start = zone.local(day.year, day.month, day.day)
      day_end = day_start + 1.day
      starts = [ block.starts_at, day_start ].max
      ends = [ block.ends_at, day_end ].min
      return nil unless ends > starts

      json(block, starts.in_time_zone(zone).strftime("%H:%M"),
           ends >= day_end ? "24:00" : ends.in_time_zone(zone).strftime("%H:%M"), catalog)
    end

    def json(block, starts, ends, catalog)
      out = { starts: starts, ends: ends, kind: block.kind }
      return out unless block.kind == "bookable"

      out[:appointment_type_key] = block.appointment_type_key
      out[:appointment_type_name] = catalog.name_for(block.appointment_type_key)
      out[:slot_minutes] = block.slot_minutes if block.slot_minutes
      out
    end
  end
end
