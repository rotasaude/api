# O CPF chega depois (ADR 0042; spec do 24a, decisão 2): o paciente digitado
# sem CPF ganha o CPF uma vez (NULL → valor; o guarda rota_patient_guard
# recusa trocar), a justificativa sai, os pares VALIDADOS do CPF sem paciente
# se ligam a ele e os dados validados substituem os digitados
# (Patients::Resolve.refresh!). Ordem de travas (Desvio 12): lock consultivo
# do CPF (o mesmo do Resolve — nunca o CPF no SQL) → pares do CPF → paciente.
# O índice único de patients.cpf é a última palavra (cpf_taken).
#
# CreateTyped delega para cá com o paciente ainda NÃO gravado (paciente novo
# com CPF): mesmas travas e checagens, sem `patient.cpf_added` (o evento é
# o `patient.created` de quem chamou).
module Patients
  module AddCpf
    CPF_INDEX = "index_patients_on_cpf".freeze

    module_function

    def call(patient:, cpf:, by:)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) if digits.nil?

      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{Resolve.lock_key(digits)})")
        pairs = Pairs.of_cpf(digits).order(:id).lock.to_a
        added_later = patient.persisted?
        if added_later
          patient.lock!
          next Result.fail(:invalid_transition) if patient.cpf.present?
        end
        next Result.fail(:cpf_taken) if Patient.where(cpf: digits).where.not(id: patient.id).exists?

        patient.assign_attributes(cpf: digits, no_cpf_reason: nil)
        patient.save!
        pairs.select { |pair| pair.patient_id.nil? }.each do |pair|
          pair.update!(patient_id: patient.id)
          DomainEvents.publish("patient.linked", patient_id: patient.id, citizen_id: pair.id)
        end
        Resolve.refresh!(patient)
        DomainEvents.publish("patient.cpf_added", patient_id: patient.id, user_id: by.id) if added_later
        Result.ok(patient: patient)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(CPF_INDEX)

      Result.fail(:cpf_taken)
    end
  end
end
