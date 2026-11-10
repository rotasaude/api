# Suspensão da prescrição interna da UPA (ADR 0050; contrato §5; plano,
# Desvio 3). Quem: o médico (225*) com vínculo ativo na UPA do encontro; os
# demais → Access.refusal. `reason` String em Catalog::SUSPENSION_REASON
# (10..500, cifrado) → senão 422 invalid_request `reason`.
#
# Sob as travas (atendimento FOR SHARE → encontro FOR NO KEY UPDATE →
# prescrição FOR UPDATE): encontro ou atendimento fechado → 409
# encounter_closed; versão que não está `active` → 422 prescription_not_active.
# Vira `suspended` (só para a frente, trigger) com quem e quando; evento
# urgency.prescription_suspended, só com ids. O motivo nunca em evento nem log.
module Urgency
  module SuspendPrescription
    EVENT = "urgency.prescription_suspended".freeze

    module_function

    # -> Result.ok(prescription:) | fail(:missing_role | :missing_link | :cbo_not_allowed | :encounter_closed |
    #    :prescription_not_active) | fail(:invalid_request, details: { path: "reason", problems: })
    def call(prescription:, reason:, by:, now: Time.current)
      encounter = prescription.urgency_encounter
      unit_id = encounter.attendance.health_unit_id
      return Result.fail(Access.refusal(by, unit_id)) unless Access.physician_link(by, unit_id)

      text = reason.is_a?(String) ? reason.strip : nil
      return refuse unless text && Catalog::SUSPENSION_REASON.cover?(text.length)

      ApplicationRecord.transaction(requires_new: true) do
        attendance = Attendance.lock("FOR SHARE").find(encounter.attendance_id)
        locked = UrgencyEncounter.lock("FOR NO KEY UPDATE").find(encounter.id)
        next Result.fail(:encounter_closed) if locked.closed? || attendance.status == "closed"

        current = UrgencyPrescription.lock.find(prescription.id)
        next Result.fail(:prescription_not_active) unless current.active?

        current.update!(status: "suspended", suspension_reason: text, status_changed_at: now, status_changed_by_user: by)
        DomainEvents.publish(EVENT, encounter_id: locked.id, prescription_id: current.id)
        Result.ok(prescription: current)
      end
    end

    def refuse = Result.fail(:invalid_request, details: { path: "reason", problems: [ { path: "reason", error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
