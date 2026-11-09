# Chamada (spec 2026-09-25 §2.1): waiting → in_care, sob lock. Exige papel e
# vínculo ativo com a unidade do atendimento (ADR 0021; F-10.5).
#
# Módulo 32a (ADR 0050; plano, Desvios 11 e 12; contrato §6 e §14 Q7):
# - no `walk_in` da UPA, só o médico (vínculo 225* na unidade, senão
#   cbo_not_allowed) chama, e só o encontro já classificado (not_classified);
#   o encontro vai a in_care na mesma transação;
# - `waiting_room` é o waiting_room_display já lido pelo chamador, FORA da
#   transação: ligado, o local passa pelo WaitingRoom::CallLocations
#   (call_location_required | invalid_call_location) e a chamada `care` é
#   gravada em attendance_calls; desligado, `call_location_id` é ignorado.
module Attendances
  class Call
    def self.call(attendance:, health_unit_id:, by:, call_location_id: nil, waiting_room: false)
      return Result.fail(:wrong_unit) unless attendance.health_unit_id == health_unit_id.to_s

      state, call = ApplicationRecord.transaction do
        attendance.lock!
        authorization = Professionals::ClinicalAuthorization.check(user: by, health_unit_id: attendance.health_unit_id)
        next authorization unless authorization == :ok
        next :cbo_not_allowed if attendance.walk_in? && !Urgency::Access.physician_link(by, attendance.health_unit_id)
        next :already_called unless attendance.status == "waiting"

        encounter = attendance.walk_in? ? attendance.urgency_encounter&.lock! : nil
        next :not_classified if attendance.walk_in? && encounter&.state != "classified"

        outcome, location = WaitingRoom::CallLocations.resolve(unit_id: attendance.health_unit_id, call_location_id: call_location_id,
                                                               enabled: waiting_room)
        next outcome unless outcome == :ok

        # ADR 0030 (Desvio 7): chamar no meio da escuta encerra a escuta.
        Screenings::Abandon.release!(attendance, by: by)
        attendance.update!(status: "in_care", called_by_user: by, called_at: Time.current)
        encounter&.update!(state: "in_care")
        record = CallRecord.record!(attendance: attendance, kind: "care", location: location, by: by, enabled: waiting_room)
        DomainEvents.publish("attendance.called", attendance_id: attendance.id, called_by_user_id: by.id)
        [ :ok, record ]
      end
      state == :ok ? Result.ok(attendance: attendance, call: call) : Result.fail(state)
    end
  end
end
