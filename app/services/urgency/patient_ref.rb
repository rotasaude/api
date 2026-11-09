# <patient-ref> do contrato §2: `{ patient_id, name, cns_masked, unidentified }`.
# A descrição do não identificado só no detalhe (detail: true) e só do
# provisório — nunca na chegada nem na fila. Nunca CPF nem CNS inteiros.
module Urgency
  module PatientRef
    module_function

    def call(patient, detail: false)
      ref = { patient_id: patient.id, name: patient.display_name, cns_masked: patient.cns_masked,
              unidentified: patient.unidentified }
      ref[:description] = patient.unidentified_description if detail && patient.unidentified
      ref
    end
  end
end
