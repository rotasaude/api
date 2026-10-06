# Vagas calculadas (ADR 0029 §4.1). A vaga nunca é gravada: sai de turnos não
# cancelados, do modelo ligado a cada turno e dos horários ativos do
# profissional. A parte de cima é PURA (recebe dados e o fuso); a carga do
# banco fica em `for` (Task 8).
#
# 1. turno cujo vínculo tem CBO servido pelo tipo pedido;
# 2. faixas: as do modelo (horas no fuso da cidade, em cada dia local que o
#    turno cobre, recortadas pelo turno); sem modelo, o turno inteiro como
#    `bookable` do tipo padrão do vínculo → senão o da base pelo CBO → senão
#    nenhuma faixa (só encaixe);
# 3. cada faixa `bookable` do tipo é cortada na duração da vaga (slot_minutes
#    da faixa ou a do tipo); a sobra do fim é descartada;
# 4. some a vaga que cruza horário ativo do profissional (qualquer modo) e a
#    que já começou.
module Scheduling
  module Availability
    Shift = Data.define(:id, :professional_id, :starts_at, :ends_at, :cbo_code, :default_type_key, :blocks, :cancelled)
    Busy = Data.define(:professional_id, :starts_at, :ends_at)
    Slot = Data.define(:professional_id, :shift_id, :starts_at, :ends_at, :appointment_type_key)
    Block = Data.define(:starts_at, :ends_at, :kind, :appointment_type_key, :slot_minutes)

    module_function

    def compute(shifts:, type:, types:, fallback:, busy:, now:, zone:, window: nil)
      shifts.reject(&:cancelled).select { |shift| type.serves?(shift.cbo_code) }.flat_map do |shift|
        blocks_for(shift, types: types, fallback: fallback, zone: zone)
          .select { |b| b.kind == "bookable" && b.appointment_type_key == type.key }
          .flat_map { |b| slice(b, b.slot_minutes || type.duration_minutes) }
          .map do |starts, ends|
            Slot.new(professional_id: shift.professional_id, shift_id: shift.id, starts_at: starts, ends_at: ends,
                     appointment_type_key: type.key)
          end
          .reject { |slot| slot.starts_at <= now || (window && !window.cover?(slot.starts_at)) }
          .reject { |slot| overlaps_busy?(slot, busy) }
      end.sort_by { |slot| [ slot.starts_at, slot.professional_id.to_s ] }
    end

    def blocks_for(shift, types:, fallback:, zone:)
      return template_blocks(shift, zone) if shift.blocks

      key = default_key(shift, types, fallback)
      return [] unless key

      [ Block.new(starts_at: shift.starts_at, ends_at: shift.ends_at, kind: "bookable", appointment_type_key: key,
                  slot_minutes: nil) ]
    end

    def default_key(shift, types, fallback)
      own = types[shift.default_type_key]
      return own.key if own&.serves?(shift.cbo_code)

      fallback.find { |t| t.serves?(shift.cbo_code) }&.key
    end

    def slice(block, minutes)
      step = minutes.to_i.minutes
      return [] unless step.positive?

      out = []
      cursor = block.starts_at
      while cursor + step <= block.ends_at
        out << [ cursor, cursor + step ]
        cursor += step
      end
      out
    end

    def template_blocks(shift, zone)
      local_days(shift, zone).flat_map do |day|
        Array(shift.blocks).filter_map do |raw|
          starts = [ local(day, raw["starts"], zone), shift.starts_at ].max
          ends = [ local(day, raw["ends"], zone), shift.ends_at ].min
          next unless ends > starts

          Block.new(starts_at: starts, ends_at: ends, kind: raw["kind"], appointment_type_key: raw["appointment_type_key"],
                    slot_minutes: raw["slot_minutes"])
        end
      end.sort_by(&:starts_at)
    end

    def local_days(shift, zone)
      shift.starts_at.in_time_zone(zone).to_date..(shift.ends_at - 1.second).in_time_zone(zone).to_date
    end

    def local(day, hhmm, zone)
      hour, min = hhmm.to_s.split(":").map(&:to_i)
      zone.local(day.year, day.month, day.day, hour, min)
    end

    def overlaps_busy?(slot, busy)
      busy.any? do |b|
        b.professional_id == slot.professional_id && b.starts_at < slot.ends_at && b.ends_at > slot.starts_at
      end
    end
  end
end
