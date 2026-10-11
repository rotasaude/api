# Atendimentos (módulo 13): chegada na unidade e desfecho. A nota de
# encaminhamento e o motivo de exceção (texto livre) nunca entram.
module Timeline
  module Sources
    module AttendanceSource
      KIND = "attendance".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        scope = ::Attendance.where(citizen_id: person.citizen_ids).includes(:health_unit, called_by_user: :professional)
        Window.apply(scope, kind: KIND, column: "attendances.checked_in_at", id_column: "attendances.id",
                            before: before, from: from, to: to)
              .limit(limit).map { |attendance| entry(attendance) }
      end

      def entry(attendance)
        unit = attendance.health_unit
        caller = attendance.called_by_user
        Entry.new(kind: KIND, source_id: attendance.id, occurred_at: attendance.checked_in_at,
                  unit: { id: unit.id, name: unit.name },
                  professional: caller && { name: Screenings::Json.staff_name(caller), cbo_code: nil },
                  title: "Atendimento — #{unit.name}", summary: Labels::ATTENDANCE_OUTCOMES[attendance.outcome],
                  status: attendance.status, detail_ref: { type: "attendance", id: attendance.id },
                  citizen: { title: "Atendimento na #{unit.name}", summary: Labels::CITIZEN_OUTCOMES[attendance.outcome],
                             status: attendance.status, professional_name: Labels.professional_name(caller) },
                  document: nil)
      end
    end
  end
end
