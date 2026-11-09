# Formas JSON da urgência (contrato §2 e §4), compartilhadas pelos
# controladores de /urgency/*. A Task 7 acrescenta o detalhe do encontro.
module Urgency
  module Json
    module_function

    # Resposta da chegada: `{ attendance_id, encounter_id, ticket | null, patient: <patient-ref> }`.
    def arrival(encounter:, attendance:, patient:)
      { attendance_id: attendance.id, encounter_id: encounter.id, ticket: attendance.ticket, patient: PatientRef.call(patient) }
    end
  end
end
