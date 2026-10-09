# app/services/clinical_record/trail.rb
# Toda leitura de prontuário deixa trilha (ADR 0031, Invariantes): ids, o
# acesso (in_context | justified | author | administrative) e o código do
# motivo — nunca a nota. A leitura administrativa leva também o id da consulta
# (o relatório das aberturas a lista a partir deste evento).
module ClinicalRecord
  module Trail
    module_function

    def viewed!(patient:, user:, grant:, consultation_id: nil)
      return unless patient

      payload = { patient_id: patient.id, user_id: user.id, access: grant.kind.to_s, reason_code: grant.opening&.reason_code }
      payload[:consultation_id] = consultation_id if consultation_id
      DomainEvents.publish("clinical_record.viewed", **payload)
    end
  end
end
