# app/commands/clinical_record/open.rb
# Abertura justificada (ADR 0031; spec §5; contratos §3): profissional com
# vínculo permitido, motivo de lista (nota de 10–500 só com other), válida 30
# minutos para aquele usuário e paciente. O step-up é do controller. CPF que
# não tem paciente (nunca consultou, ou só par declarado) = patient_not_found.
module ClinicalRecord
  module Open
    module_function

    def call(user:, cpf:, reason_code:, reason_note: nil)
      status, _link = Consultations::Authorization.any_allowed_link(user: user)
      return Result.fail(status) unless status == :ok

      code = reason_code.is_a?(String) ? reason_code : nil
      return Result.fail(:invalid_reason) unless ClinicalRecordOpening::REASONS.include?(code)

      note = nil
      if code == "other"
        note = reason_note.is_a?(String) ? reason_note.strip : ""
        return Result.fail(:invalid_reason) unless note.length.between?(ClinicalRecordOpening::MIN_NOTE, ClinicalRecordOpening::MAX_NOTE)
      end

      digits = CitizenIdentity::Cpf.normalize(cpf)
      patient = digits && Patient.find_by(cpf: digits)
      return Result.fail(:patient_not_found) unless patient

      now = Time.current
      opening = ClinicalRecordOpening.create!(patient: patient, user: user, reason_code: code, reason_note: note,
                                              created_at: now, expires_at: now + ClinicalRecordOpening::VALIDITY)
      DomainEvents.publish("clinical_record.opened", opening_id: opening.id, patient_id: patient.id, user_id: user.id,
                                                     reason_code: code)
      Result.ok(opening: opening)
    end
  end
end
