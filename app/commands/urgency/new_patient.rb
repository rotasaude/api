# Paciente novo digitado na urgência (contrato §14 Q4, Q23): a forma
# `new_patient` do 24a (Patients::CreateTyped) com a conferência de duplicado
# do Patients::CreateReviewed (trava da match_key contra criação simultânea),
# como a farmácia, a vacina e a vigilância. Usado pela chegada (Arrive) e pela
# identificação (Task 9). O provisório (`unidentified`) NÃO passa por aqui: quem
# está grave não espera a conferência.
#
# Duplicado suspeito → duplicate_suspected `path: "new_patient"` com só os ids
# dos candidatos (`candidate_ids`, a regra do Patients::Duplicates, no máximo
# 10); quem responde mostra a forma do candidato. Nada da pessoa em
# Result.details: só o path e ids.
module Urgency
  module NewPatient
    ALLOWED = Patients::CreateTyped::STRINGS
    KEY_PATH_MAX = 64
    CANDIDATES_MAX = Patients::Duplicates::MAX
    # As recusas do CreateTyped/CreateReviewed com o caminho do corpo (new_patient.*).
    TYPED_PATHS = { invalid_cpf: "new_patient.cpf", invalid_cns: "new_patient.cns", cpf_taken: "new_patient.cpf",
                    cns_taken: "new_patient.cns", cpf_or_reason_required: "new_patient.no_cpf_reason" }.freeze

    module_function

    # Só a forma, sem banco: `new_patient` objeto sem chave desconhecida e
    # `duplicates_reviewed` booleano (ausente = false).
    # -> Result.ok(new_patient:, reviewed:) | fail(:invalid_request, details: { path: })
    def parse(new_patient, duplicates_reviewed)
      return refuse(:invalid_request, "new_patient") unless new_patient.is_a?(Hash)

      unknown = (new_patient.keys.map(&:to_s) - ALLOWED).first
      return refuse(:invalid_request, "new_patient.#{unknown}"[0, KEY_PATH_MAX]) if unknown

      reviewed = duplicates_reviewed.nil? ? false : duplicates_reviewed
      return refuse(:invalid_request, "duplicates_reviewed") unless [ true, false ].include?(reviewed)

      Result.ok(new_patient: new_patient.to_h.stringify_keys, reviewed: reviewed)
    end

    # Dentro da transação de quem chama (a trava da match_key dura até o fim dela).
    # -> Result.ok(patient:) | fail(:duplicate_suspected, details: { path:, candidate_ids: }) | a recusa com o path
    def create(new_patient:, reviewed:, by:)
      shape = Patients::CreateTyped.check(new_patient)
      return typed_failure(shape) if shape.failure?

      created = Patients::CreateReviewed.call(new_patient: new_patient, reviewed: reviewed, by: by)
      return created if created.ok?
      return typed_failure(created) unless created.reason == :duplicate_suspected

      Result.fail(:duplicate_suspected, details: { path: "new_patient", candidate_ids: candidate_ids(new_patient) })
    end

    # Identificação do provisório por dados novos (Urgency::Identify; §14 Q23):
    # a mesma forma e a mesma conferência de duplicado, mas os dados vão para
    # o PRÓPRIO provisório (já travado por quem chama), que deixa de ser
    # provisório. A descrição fica. CNS de outro paciente → cns_taken; o CPF
    # entra pelo Patients::AddCpf (travas, cpf_taken, pares validados), depois
    # de o provisório deixar de sê-lo (ck_patients_unidentified).
    # -> Result.ok(patient:) | fail(:duplicate_suspected, details: { path:, candidate_ids: }) | a recusa com o path
    def assign(patient:, new_patient:, reviewed:, by:)
      shape = Patients::CreateTyped.check(new_patient)
      return typed_failure(shape) if shape.failure?

      reviewed_result = Patients::CreateReviewed.review(new_patient, reviewed)
      unless reviewed_result.ok?
        return Result.fail(:duplicate_suspected, details: { path: "new_patient", candidate_ids: candidate_ids(new_patient) })
      end

      values, cpf = shape.payload.values_at(:values, :cpf)
      return refuse(:cns_taken, TYPED_PATHS[:cns_taken]) if values["cns"] && Patient.where(cns: values["cns"]).where.not(id: patient.id).exists?

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        # Com CPF, a justificativa do provisório fica até o AddCpf trocá-la (ck_patients_cpf_or_reason).
        patient.update!(values.merge("unidentified" => false, "no_cpf_reason" => values["no_cpf_reason"] || patient.no_cpf_reason))
        result = cpf ? Patients::AddCpf.call(patient: patient, cpf: cpf, by: by) : Result.ok(patient: patient)
        if result.failure?
          result = typed_failure(result)
          raise ActiveRecord::Rollback
        end
      end
      result
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(Patients::CreateTyped::CNS_INDEX)

      refuse(:cns_taken, TYPED_PATHS[:cns_taken])
    end

    # Os mesmos candidatos da conferência (com CPF digitado, só os sem CPF).
    def candidate_ids(typed)
      Patients::Duplicates.call(full_name: typed["full_name"], birth_date: typed["birth_date"], mother_name: typed["mother_name"],
                                limit: CANDIDATES_MAX, only_without_cpf: typed["cpf"].present?).map(&:id)
    end

    def typed_failure(result)
      refuse(result.reason, TYPED_PATHS[result.reason] || result.details.fetch(:path, "new_patient"))
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :candidate_ids, :typed_failure, :refuse
  end
end
