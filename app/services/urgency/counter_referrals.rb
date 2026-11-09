# Retornos pedidos pela urgência à UBS (ADR 0050; contrato §7 e §14 Q11,
# Q20): as altas com retorno à UBS (`discharged_to_primary_care`) cuja equipe
# de referência do paciente (gravada no desfecho) é desta unidade, dos últimos
# COUNTER_REFERRAL_WINDOW, do mais recente ao mais antigo. É o "aviso
# interno" do contrato: sem evento novo, sem trilha (é lista) e nunca o
# motivo do retorno (cifrado no desfecho).
module Urgency
  module CounterReferrals
    module_function

    # -> [ { encounter_id, patient: <patient-ref>, upa: { name }, closed_at, return_days, due_on } ]
    def for(unit:, now: Time.current)
      UrgencyOutcome.where(counter_referral_health_unit_id: unit.id, kind: "discharged_to_primary_care")
                    .where(recorded_at: (now - Catalog::COUNTER_REFERRAL_WINDOW)..now)
                    .includes(urgency_encounter: { attendance: %i[patient health_unit] })
                    .order(recorded_at: :desc, id: :desc)
                    .map { |outcome| item(outcome) }
    end

    def item(outcome)
      attendance = outcome.urgency_encounter.attendance
      closed_at = attendance.closed_at || outcome.recorded_at
      { encounter_id: outcome.urgency_encounter_id, patient: PatientRef.call(attendance.patient),
        upa: { name: attendance.health_unit.name }, closed_at: closed_at.iso8601, return_days: outcome.return_days,
        due_on: (closed_at.to_date + outcome.return_days).iso8601 }
    end
    private_class_method :item
  end
end
