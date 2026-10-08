# app/services/clinical_record/trail.rb
# Toda leitura de prontuário deixa trilha (ADR 0031, Invariantes): ids, o
# acesso (in_context | justified) e o código do motivo — nunca a nota.
module ClinicalRecord
  module Trail
    module_function

    def viewed!(patient:, user:, grant:)
      return unless patient

      DomainEvents.publish("clinical_record.viewed", patient_id: patient.id, user_id: user.id, access: grant.kind.to_s,
                                                     reason_code: grant.opening&.reason_code)
    end
  end
end
