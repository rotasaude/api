# Saída da observação sem desfecho (ADR 0050; contrato §4 e §10): o paciente
# sai do leito e volta ao atendimento (o encontro segue `in_care`).
#
# Quem: só quem tem acesso clínico na UPA (Access.clinical_link: 2235* ou
# 225*); os demais → Access.refusal (missing_role | missing_link |
# cbo_not_allowed).
#
# Numa transação, na ordem de trava das escritas clínicas da urgência
# (atendimento FOR SHARE → encontro FOR NO KEY UPDATE → estadia aberta FOR
# UPDATE): encontro ou atendimento fechado → 409 encounter_closed; sem estadia
# aberta → 422 not_in_observation. Fecha a estadia em `now` com
# `observation_ended` e publica `urgency.observation_ended` (só encounter_id e
# stay_id). A saída com desfecho é do Urgency::RecordOutcome (`outcome`).
module Urgency
  module EndObservation
    module_function

    # -> Result.ok(stay:) | fail(:missing_role | :missing_link | :cbo_not_allowed | :encounter_closed | :not_in_observation)
    def call(encounter:, by:, now: Time.current)
      unit_id = encounter.attendance.health_unit_id
      return Result.fail(Access.refusal(by, unit_id)) unless Access.clinical_link(by, unit_id)

      ApplicationRecord.transaction(requires_new: true) do
        attendance = Attendance.lock("FOR SHARE").find(encounter.attendance_id)
        locked = UrgencyEncounter.lock("FOR NO KEY UPDATE").find(encounter.id)
        next Result.fail(:encounter_closed) if locked.closed? || attendance.status == "closed"

        stay = UrgencyBedStay.open_stays.lock.find_by(urgency_encounter_id: locked.id)
        next Result.fail(:not_in_observation) unless stay

        stay.update!(ended_at: now, end_kind: "observation_ended", ended_by_user: by)
        DomainEvents.publish("urgency.observation_ended", encounter_id: locked.id, stay_id: stay.id)
        Result.ok(stay: stay)
      end
    end
  end
end
