# Painel da TV (ADR 0050; contrato §8 e §14 Q8; Valor fixado 6):
#   - calls: as 8 chamadas mais recentes da unidade nos últimos 30 min, só as
#     com senha — senha, nome do local, tipo e hora;
#   - wait_times: só numa UPA com `health_units.show_wait_times` e o
#     `show_wait_times` da TV ligados (senão nil). Por cor de COLORS, a
#     mediana em minutos inteiros de `now - checked_in_at` de quem AINDA
#     espera o médico já classificado nessa cor (a mesma definição da fila,
#     Urgency::Queue.classified); menos de 5 → "lt5_patients", para que a
#     contagem pequena não identifique ninguém.
# Nunca nome, CPF, CNS, cor da pessoa, queixa nem id de paciente, encontro ou
# atendimento. Só leitura: sem trilha e sem evento.
module WaitingRoom
  module Board
    CALLS = 8
    WINDOW = 30.minutes
    MIN_PATIENTS = 5
    SMALL = "lt5_patients".freeze

    module_function

    def call(display:, now: Time.current)
      unit = display.health_unit
      {
        unit: { name: unit.name },
        calls: calls(unit, now),
        wait_times: wait_times?(unit, display) ? wait_times(unit, now) : nil,
        updated_at: now.iso8601
      }
    end

    def calls(unit, now)
      AttendanceCall.joins(:attendance).where(attendances: { health_unit_id: unit.id })
                    .where.not(ticket: nil).where(called_at: (now - WINDOW)..now)
                    .includes(:call_location).order(called_at: :desc, id: :desc).limit(CALLS)
                    .map { |c| { ticket: c.ticket, location: c.call_location&.name, kind: c.kind, called_at: c.called_at.iso8601 } }
    end

    def wait_times?(unit, display) = unit.upa? && unit.show_wait_times && display.show_wait_times

    def wait_times(unit, now)
      waits = Urgency::Queue.classified(unit.id).reorder(nil)
                            .pluck("queue_classifications.color", "attendances.checked_in_at")
                            .group_by(&:first).transform_values { |rows| rows.map { |(_, at)| (now - at) / 60.0 } }
      Urgency::Catalog::COLORS.map do |color|
        minutes = waits.fetch(color, [])
        { color: color, median_minutes: minutes.size < MIN_PATIENTS ? SMALL : median(minutes).floor }
      end
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    private_class_method :calls, :wait_times?, :wait_times, :median
  end
end
