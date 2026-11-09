# Chamada para a classificação (ADR 0050; contrato §6 e §14 Q2, Q7; plano,
# Desvio 12): a enfermagem (2235* com vínculo na UPA, Urgency::Access.classifier:
# missing_role | missing_link | cbo_not_allowed — o técnico 3222 não) chama o
# encontro aberto para classificar ou reclassificar. Não muda o estado do
# atendimento nem do encontro. Encontro (ou atendimento) fechado →
# encounter_closed.
#
# `waiting_room` é o waiting_room_display já lido pelo chamador, FORA da
# transação: ligado, o local pelo WaitingRoom::CallLocations e a chamada
# `classification` em attendance_calls; desligado, nada é gravado e o local é
# ignorado (call nulo).
module Urgency
  module CallForClassification
    module_function

    # -> Result.ok(call: AttendanceCall | nil) | Result.fail(reason)
    def call(encounter:, call_location_id:, by:, waiting_room:)
      attendance = encounter.attendance
      access = Access.classifier(by, attendance.health_unit_id)
      return access if access.failure?

      ApplicationRecord.transaction do
        attendance.lock!
        encounter.lock!
        next Result.fail(:encounter_closed) if encounter.closed? || attendance.status == "closed"

        outcome, location = WaitingRoom::CallLocations.resolve(unit_id: attendance.health_unit_id, call_location_id: call_location_id,
                                                               enabled: waiting_room)
        next Result.fail(outcome) unless outcome == :ok

        Result.ok(call: Attendances::CallRecord.record!(attendance: attendance, kind: "classification", location: location, by: by,
                                                        enabled: waiting_room))
      end
    end
  end
end
