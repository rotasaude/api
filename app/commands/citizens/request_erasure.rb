# ADR 0026: o citizen_verifier registra no posto, com documento conferido, o
# pedido de exclusão de TODOS os pares do CPF. CPF com par atendido nasce
# retido por base legal; o mesmo vale para CPF com documento clínico emitido
# e para CPF com exame (ADR 0036, A49). `retained?` é a regra única: o pedido
# e a reconferência do Citizens::Erase usam a mesma.
module Citizens
  module RequestErasure
    module_function

    def call(cpf:, document_checked:, by:)
      return Result.fail(:document_check_required) unless document_checked == true

      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      pairs = pairs_of(digits)
      return Result.fail(:citizen_not_found) if pairs.empty?

      request = nil
      ApplicationRecord.transaction do
        retained = retained?(pairs, cpf: digits)
        request = CitizenErasureRequest.create!(
          cpf: digits, presented_citizen: pairs.order(:created_at).first, requested_by_user: by,
          document_checked: true, status: retained ? "retained" : "pending", decided_at: (Time.current if retained)
        )
        DomainEvents.publish(retained ? "citizen.erasure_retained" : "citizen.erasure_requested", request_id: request.id)
      end
      Result.ok(request: request)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idx_citizen_erasure_requests_one_pending")

      Result.fail(:already_pending)
    end

    def pairs_of(digits) = Citizen.not_erased.where(cpf: digits)

    # A regra única de retenção. O Citizens::Erase a aplica em dois passos
    # (os pares, depois o paciente travado), sem mudar a regra.
    def retained?(pairs, cpf:) = clinical_on_pairs?(pairs) || examined?(pairs, cpf: cpf)

    # Registros com FK para o par: a trava do par já os protege.
    def clinical_on_pairs?(pairs) = attended?(pairs) || documented?(pairs)

    def attended?(pairs) = Attendance.where(citizen_id: pairs.select(:id)).exists?

    # ADR 0033 (spec §8): documento clínico emitido é registro retido.
    def documented?(pairs) = ClinicalDocument.where(citizen_id: pairs.select(:id)).exists?

    # ADR 0036 (A49): exame é registro clínico — pedido em qualquer situação,
    # cancelado inclusive, ou resultado externo do paciente da pessoa.
    def examined?(pairs, cpf:) = examined_patients?(patient_ids(pairs, cpf: cpf))

    def examined_patients?(ids) = ExamOrder.where(patient_id: ids).exists? || ExamResult.where(patient_id: ids).exists?

    # O paciente dos pares e o do CPF: o exame aponta para o paciente, que
    # pode ter ficado de um par já excluído (o CPF do paciente é cifrado de
    # forma determinística, como no ClinicalRecord::Open).
    def patient_ids(pairs, cpf:)
      (pairs.where.not(patient_id: nil).pluck(:patient_id) + Patient.where(cpf: cpf).pluck(:id)).uniq
    end
  end
end
