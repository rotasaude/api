# POST /transport/my_trips/:id/attendance (contrato §5): o motorista marca a
# presença do paciente e, separada, a do acompanhante, em viagem
# `in_progress`; `items[]` parciais (só os mandados mudam), tudo ou nada.
# Viagem done/cancelled → `trip_not_open`; planned/confirmed →
# `invalid_transition`; passageiro que não é ativo desta viagem → not_found;
# `companion_attendance` só onde há acompanhante. Depois do `done` a presença
# congela (trigger) e só a central corrige (Transport::CorrectAttendance).
module Transport
  module RecordAttendance
    module_function

    # -> Result.ok(trip:) | fail(:invalid_request, details: { path:, problems: }) |
    #    fail(:trip_not_open | :invalid_transition | :not_found | :passenger_anonymized)
    def call(trip:, items:, by:)
      list, problems = AttendanceItems.parse(items, statuses: Catalog::ATTENDANCE)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:trip_not_open) if ConfirmTrip::CLOSED.include?(trip.status)
        next Result.fail(:invalid_transition) unless trip.status == "in_progress"
        next Support.refuse(problems) if problems.any?

        passengers = AttendanceItems.load(trip, list)
        next Result.fail(:not_found) unless passengers
        next Result.fail(:passenger_anonymized) if passengers.values.any?(&:anonymized_at)

        problems = AttendanceItems.companion_problems(list, passengers)
        next Support.refuse(problems) if problems.any?

        list.each do |item|
          changes = { attendance: item.attendance }
          changes[:companion_attendance] = item.companion_attendance if item.companion_attendance
          passengers.fetch(item.passenger_id).update!(changes)
        end
        Result.ok(trip: trip)
      end
    end
  end
end
