# "Chamar de novo" (ADR 0050; contrato §6 e §14 Q7; plano, Desvio 12): grava
# outra chamada do atendimento, do mesmo tipo da última (classificação ou
# atendimento), sem mudar o estado. Na UPA e na UBS.
#
# `waiting_room` é o waiting_room_display já lido pelo chamador, FORA da
# transação: desligado → feature_disabled. Exige papel e vínculo com a unidade
# (Professionals::ClinicalAuthorization); atendimento encerrado →
# already_closed; sem chamada anterior → not_called; o local pelo
# WaitingRoom::CallLocations. Evento attendance.recalled só com ids.
module Attendances
  class Recall
    # -> Result.ok(call:) | Result.fail(reason)
    def self.call(attendance:, call_location_id:, by:, waiting_room:)
      return Result.fail(:feature_disabled, details: { feature: WaitingRoom::Gate::KEY }) unless waiting_room

      ApplicationRecord.transaction do
        attendance.lock!
        authorization = Professionals::ClinicalAuthorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next Result.fail(authorization) unless authorization == :ok
        next Result.fail(:already_closed) unless attendance.open?

        last = AttendanceCall.where(attendance_id: attendance.id).order(called_at: :desc, id: :desc).first
        next Result.fail(:not_called) unless last

        outcome, location = WaitingRoom::CallLocations.resolve(unit_id: attendance.health_unit_id, call_location_id: call_location_id,
                                                               enabled: true)
        next Result.fail(outcome) unless outcome == :ok

        call = CallRecord.record!(attendance: attendance, kind: last.kind, location: location, by: by, enabled: true)
        DomainEvents.publish(
          "attendance.recalled",
          attendance_id: attendance.id, call_id: call.id
        )
        Result.ok(call: call)
      end
    end
  end
end
