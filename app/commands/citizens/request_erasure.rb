# ADR 0026: o citizen_verifier registra no posto, com documento conferido, o
# pedido de exclusão de TODOS os pares do CPF. CPF com par atendido nasce
# retido por base legal; o mesmo vale para CPF com documento clínico emitido
# e para CPF com exame (ADR 0036, A49) ou inscrição em linha de cuidado
# (ADR 0040), para CPF com cadastro territorial (ADR 0042) e para CPF com
# notificação de vigilância (ADR 0043), para CPF com pedido de regulação
# (ADR 0044) e para CPF com dispensação ou receita externa da farmácia
# (ADR 0045). `retained?` é a regra única: o pedido
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

    # ADR 0037: a requisição do laboratório municipal (com amostras, resultados
    # e laudos que pendem dela) também é registro clínico retido.
    # ADR 0039: o procedimento realizado (e o arquivo BPA que o leva) também,
    # cancelado inclusive (o arquivo pode já tê-lo levado).
    # ADR 0040: a inscrição em linha de cuidado (e os contatos de busca
    # ativa, que pendem dela) também é registro clínico retido. A condição
    # declarada pelo cidadão não retém (é apagada na exclusão).
    # ADR 0042: o cadastro territorial também é registro retido — quem tem
    # QUALQUER versão de cadastro individual (ativo ou não) ou é o responsável
    # de uma família (contrato §14 L13).
    # ADR 0043: a notificação de doença compulsória também é registro retido —
    # qualquer situação, descartada inclusive (obrigação legal).
    # ADR 0044: o pedido de regulação também é registro retido, em qualquer
    # situação (rascunho inclusive).
    # ADR 0045: dispensação e receita externa são registro clínico retido, como
    # o prontuário. Os movimentos de estoque não dependem do paciente e nunca
    # entram aqui.
    def examined_patients?(ids)
      ExamOrder.where(patient_id: ids).exists? || ExamResult.where(patient_id: ids).exists? ||
        LabRequisition.where(patient_id: ids).exists? || PerformedProcedure.where(patient_id: ids).exists? ||
        CareLineEnrollment.where(patient_id: ids).exists? || territory_registered?(ids) || notified?(ids) ||
        regulated?(ids) || dispensed?(ids)
    end

    # ADR 0045: dispensação (qualquer receita) e receita externa digitada na
    # farmácia, inclusive a que ainda não foi dispensada.
    def dispensed?(ids) = Dispensation.where(patient_id: ids).exists? || ExternalPrescription.where(patient_id: ids).exists?

    # ADR 0043: obrigação legal — notificação em qualquer situação, descartada inclusive.
    def notified?(ids) = DiseaseNotification.where(patient_id: ids).exists?

    # ADR 0044: o pedido de regulação é registro clínico retido, em qualquer situação.
    def regulated?(ids) = RegulationRequest.where(patient_id: ids).exists?

    # ADR 0042: versão de cadastro individual (a imutável, não só o cabeçalho
    # ativo) ou responsável de família.
    def territory_registered?(ids)
      IndividualRegistrationVersion.where(patient_id: ids).exists? || Family.where(responsible_patient_id: ids).exists?
    end

    # O paciente dos pares e o do CPF: o exame aponta para o paciente, que
    # pode ter ficado de um par já excluído (o CPF do paciente é cifrado de
    # forma determinística, como no ClinicalRecord::Open).
    def patient_ids(pairs, cpf:)
      (pairs.where.not(patient_id: nil).pluck(:patient_id) + Patient.where(cpf: cpf).pluck(:id)).uniq
    end
  end
end
