# A pessoa da visita, do participante da atividade coletiva e do item
# `patient` do envio do app (módulo 24b, ADR 0052; contrato §5, §13; Q8, Q15,
# Q21, Q32, Q41): `patient_id` de um paciente existente, ou `new_patient` (a
# forma do 24a) criado pelo Patients::CreateReviewed — savepoint próprio,
# DENTRO da transação de quem grava: a recusa desfaz só a pessoa, e a trava da
# match_key dura até o fim da transação de fora.
#
# Recusas com os códigos reais (os do 24a: invalid_patient, cpf_or_reason_required,
# invalid_cpf, invalid_cns, cpf_taken, cns_taken; e duplicate_suspected,
# patient_unidentified, not_found, invalid_request), sempre com o `path` do
# campo, relativo ao item pelo `path_prefix` ("" na visita, "participants[i]"
# na atividade; o envio do app, relativo ao body): `new_patient.cpf`,
# `participants[1].new_patient`, `patient_id`… Nunca o valor: nome,
# nascimento, sexo, mãe, CPF e CNS não vão a Result.details, log nem evento.
#
# Duplicado suspeito: até 10 candidatos (a regra do Patients::Duplicates; com
# CPF digitado, só os sem CPF) na forma `candidate`, mais os `candidate_ids`.
# `resolve` NÃO grava a trilha: quem chama desfaz a transação quando outro
# participante ou o item é recusado, e a trilha iria junto. Quem mostra os
# candidatos chama `candidates_viewed!` DEPOIS da sua transação, qualquer que
# seja o desfecho (o padrão do Urgency::NewPatient + Urgency::BaseController
# #duplicate_candidates), com o módulo da trilha do seu acesso.
module HomeVisits
  module People
    # A forma do §5 (sem social_name, que o registro rápido não tem).
    ALLOWED = %w[full_name birth_date sex mother_name cpf no_cpf_reason cns].freeze
    KEY_PATH_MAX = 64
    CANDIDATES_MAX = Patients::Duplicates::MAX
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # As recusas do CreateTyped sem caminho próprio → o campo do new_patient.
    TYPED_PATHS = { invalid_cpf: "new_patient.cpf", invalid_cns: "new_patient.cns", cpf_taken: "new_patient.cpf",
                    cns_taken: "new_patient.cns", cpf_or_reason_required: "new_patient.no_cpf_reason" }.freeze

    module_function

    # `reviewed` é o `duplicates_reviewed` do corpo, opcional: nil vale false.
    # -> Result.ok(patient:, created:) |
    #    Result.fail(<código>, details: { path: } | { path:, candidates:, candidate_ids: })
    def resolve(by:, patient_id: nil, new_patient: nil, reviewed: false, path_prefix: "")
      at = ->(path) { path_prefix.to_s.empty? ? path : "#{path_prefix}.#{path}" }
      return refuse(:invalid_request, at["new_patient"]) if !patient_id.nil? && !new_patient.nil?
      return existing(patient_id, at) unless patient_id.nil? && !new_patient.nil?

      return refuse(:invalid_request, at["new_patient"]) unless new_patient.is_a?(Hash)

      unknown = (new_patient.keys.map(&:to_s) - ALLOWED).first
      return refuse(:invalid_request, at["new_patient.#{unknown}"][0, KEY_PATH_MAX]) if unknown
      reviewed = false if reviewed.nil?
      return refuse(:invalid_request, at["duplicates_reviewed"]) unless [ true, false ].include?(reviewed)

      create(new_patient.to_h.stringify_keys, reviewed, by, at)
    end

    # `{ patient_id, display_name, birth_date, sex, has_cpf, has_cns }` (Q8);
    # nos itens do 24a do app, também `registration_id` (o cadastro individual
    # ativo, ou nulo; Q26). Nunca CPF nem CNS.
    def candidate(patient, registration: false)
      json = Pharmacy::Json.duplicate(patient).merge(sex: patient.sex, has_cns: patient.cns.present?)
      return json unless registration

      json.merge(registration_id: IndividualRegistration.active_registrations.where(patient_id: patient.id).pick(:id))
    end

    # A forma da busca por documento (§5): a do 27a/29 com birth_date e sex.
    def person(patient)
      { patient_id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, sex: patient.sex,
        **Patients::IdentifierJson.call(patient) }
    end

    # Os candidatos de nome + nascimento (+ mãe), na forma `candidate`, sem
    # trilha: quem os mostra chama `candidates_viewed!`.
    def duplicates(full_name:, birth_date:, mother_name: nil, only_without_cpf: false)
      Patients::Duplicates.call(full_name: full_name, birth_date: birth_date, mother_name: mother_name, limit: CANDIDATES_MAX,
                                only_without_cpf: only_without_cpf).first(CANDIDATES_MAX).map { |patient| candidate(patient) }
    end

    # Trilha dos candidatos mostrados (um clinical_record.viewed por id), fora
    # da transação que gravaria a pessoa. `trail:` é obrigatório: o módulo do
    # acesso de quem mostra (HomeVisits::Trail, CollectiveActivities::Trail, o
    # do envio do app).
    def candidates_viewed!(candidate_ids:, by:, trail:)
      Array(candidate_ids).each { |id| trail.person_viewed!(user: by, patient_id: id) }
    end

    def existing(id, at)
      path = at["patient_id"]
      return refuse(:invalid_request, path) unless id.is_a?(String) && id.match?(UUID)

      patient = Patient.find_by(id: id)
      return refuse(:not_found, path) unless patient
      # O provisório da UPA nunca é a pessoa da ficha 8 nem da 6 (Q41).
      return refuse(:patient_unidentified, path) if patient.unidentified || patient.no_cpf_reason == "unidentified"

      Result.ok(patient: patient, created: false)
    end

    def create(typed, reviewed, by, at)
      shape = Patients::CreateTyped.check(typed)
      return typed_failure(shape, at) if shape.failure?

      created = Patients::CreateReviewed.call(new_patient: typed, reviewed: reviewed, by: by)
      return Result.ok(patient: created.payload.fetch(:patient), created: true) if created.ok?
      return typed_failure(created, at) unless created.reason == :duplicate_suspected

      candidates = duplicates(full_name: typed["full_name"], birth_date: typed["birth_date"], mother_name: typed["mother_name"],
                              only_without_cpf: typed["cpf"].present?)
      Result.fail(:duplicate_suspected, details: { path: at["new_patient"], candidates: candidates,
                                                   candidate_ids: candidates.map { |json| json[:patient_id] } })
    end

    def typed_failure(result, at)
      path = TYPED_PATHS[result.reason] || result.details[:path] || "new_patient"
      refuse(result.reason, at[path])
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :existing, :create, :typed_failure, :refuse
  end
end
