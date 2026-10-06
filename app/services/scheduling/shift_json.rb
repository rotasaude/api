# Turno numa agenda do dia (contratos §4.5, §9, §10): instantes do turno,
# cancelled_at (o cancelado aparece, marcado) e as faixas efetivas recortadas
# pelo dia local. Turno sem modelo = uma faixa `bookable` do tipo resolvido, ou
# nenhuma. Comum à agenda da unidade e à Minha agenda.
module Scheduling
  module ShiftJson
    module_function

    def call(shift, day:, catalog:, zone:)
      blocks = Availability.blocks_for(Availability.shift_data(shift), types: catalog.active, fallback: catalog.fallback,
                                                                       zone: zone)
      { shift_id: shift.id, starts_at: shift.starts_at.iso8601, ends_at: shift.ends_at.iso8601,
        cancelled_at: shift.cancelled_at&.iso8601,
        blocks: BlockJson.for_day(blocks, day: day, zone: zone, catalog: catalog) }
    end
  end
end
