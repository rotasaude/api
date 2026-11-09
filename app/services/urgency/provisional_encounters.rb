# Provisórios para identificar (ADR 0050; contrato §14 Q25, Q29): os
# encontros da UPA cujo paciente ainda é o provisório não identificado
# (`unidentified`, sem `merged_into_id`) — quem foi identificado, pela fusão
# (o atendimento passa ao real) ou como paciente novo (o provisório deixa de
# ser `unidentified`), sai da lista. Janela de WINDOW: o encontro aberto pela
# chegada (`attendances.checked_in_at`); o fechado pelo fechamento
# (`attendances.closed_at`, ou o `recorded_at` do desfecho). Fica de fora o
# `registered_in_error` (NON_CARE_OUTCOMES): é engano, não uma pessoa a
# identificar. Da chegada mais recente à mais antiga.
#
# Item: `{ encounter_id, attendance_id, arrived_at, closed_at, outcome_kind,
# patient: <patient-ref com description> }`. Nenhum dado clínico (cor,
# queixa, sinais, motivos). Quem renderiza grava a trilha por paciente.
module Urgency
  module ProvisionalEncounters
    WINDOW = 7.days
    CLOSED_AT_SQL = "COALESCE(attendances.closed_at, urgency_outcomes.recorded_at)".freeze

    module_function

    # -> [ { encounter_id:, attendance_id:, arrived_at:, closed_at:, outcome_kind:, patient: } ]
    def for(unit:, now: Time.current)
      since = now - WINDOW
      UrgencyEncounter.joins(attendance: :patient).left_joins(:outcome)
                      .where(attendances: { health_unit_id: unit.id }, patients: { unidentified: true, merged_into_id: nil })
                      .where("urgency_outcomes.kind IS NULL OR urgency_outcomes.kind NOT IN (?)", Catalog::NON_CARE_OUTCOMES)
                      .where("(urgency_encounters.state <> 'closed' AND attendances.checked_in_at >= :since) OR " \
                             "(urgency_encounters.state = 'closed' AND #{CLOSED_AT_SQL} >= :since)", since: since)
                      .includes(:outcome, attendance: :patient)
                      .order("attendances.checked_in_at DESC, urgency_encounters.id DESC")
                      .map { |encounter| item(encounter) }
    end

    def item(encounter)
      attendance = encounter.attendance
      closed_at = encounter.closed? ? (attendance.closed_at || encounter.outcome&.recorded_at) : nil
      { encounter_id: encounter.id, attendance_id: attendance.id, arrived_at: attendance.checked_in_at.iso8601,
        closed_at: closed_at&.iso8601, outcome_kind: encounter.outcome&.kind,
        patient: PatientRef.call(attendance.patient, detail: true) }
    end
    private_class_method :item
  end
end
