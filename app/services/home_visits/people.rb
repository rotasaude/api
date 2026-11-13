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
# CPF digitado, só os sem CPF) na forma `candidate`, com trilha por candidato
# mostrado (`trail:`, o módulo da trilha do chamador). A trilha é gravada na
# transação de quem chama: quem recusa o item sem ROLLBACK (nada gravado antes
# da pessoa) a mantém.
module HomeVisits
  module People
    ALLOWED = Patients::CreateTyped::STRINGS
    KEY_PATH_MAX = 64
    CANDIDATES_MAX = Patients::Duplicates::MAX
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # As recusas do CreateTyped sem caminho próprio → o campo do new_patient.
    TYPED_PATHS = { invalid_cpf: "new_patient.cpf", invalid_cns: "new_patient.cns", cpf_taken: "new_patient.cpf",
                    cns_taken: "new_patient.cns", cpf_or_reason_required: "new_patient.no_cpf_reason" }.freeze

    module_function

    # -> Result.ok(patient:, created:) | Result.fail(<código>, details: { path: } | { path:, candidates: })
    def resolve(by:, patient_id: nil, new_patient: nil, reviewed: false, path_prefix: "", trail: Trail)
      at = ->(path) { path_prefix.to_s.empty? ? path : "#{path_prefix}.#{path}" }
      return refuse(:invalid_request, at["new_patient"]) if !patient_id.nil? && !new_patient.nil?
      return existing(patient_id, at) unless patient_id.nil? && !new_patient.nil?

      return refuse(:invalid_request, at["new_patient"]) unless new_patient.is_a?(Hash)

      unknown = (new_patient.keys.map(&:to_s) - ALLOWED).first
      return refuse(:invalid_request, at["new_patient.#{unknown}"][0, KEY_PATH_MAX]) if unknown
      return refuse(:invalid_request, at["duplicates_reviewed"]) unless [ true, false ].include?(reviewed)

      create(new_patient.to_h.stringify_keys, reviewed, by, at, trail)
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

    # Os candidatos de nome + nascimento (+ mãe), com a trilha de cada um.
    def duplicates(full_name:, birth_date:, by:, trail:, mother_name: nil, only_without_cpf: false)
      found = Patients::Duplicates.call(full_name: full_name, birth_date: birth_date, mother_name: mother_name, limit: CANDIDATES_MAX,
                                        only_without_cpf: only_without_cpf).first(CANDIDATES_MAX)
      found.each { |patient| trail.person_viewed!(user: by, patient_id: patient.id) }
      found.map { |patient| candidate(patient) }
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

    def create(typed, reviewed, by, at, trail)
      shape = Patients::CreateTyped.check(typed)
      return typed_failure(shape, at) if shape.failure?

      created = Patients::CreateReviewed.call(new_patient: typed, reviewed: reviewed, by: by)
      return Result.ok(patient: created.payload.fetch(:patient), created: true) if created.ok?
      return typed_failure(created, at) unless created.reason == :duplicate_suspected

      candidates = duplicates(full_name: typed["full_name"], birth_date: typed["birth_date"], mother_name: typed["mother_name"],
                              only_without_cpf: typed["cpf"].present?, by: by, trail: trail)
      Result.fail(:duplicate_suspected, details: { path: at["new_patient"], candidates: candidates })
    end

    def typed_failure(result, at)
      path = TYPED_PATHS[result.reason] || result.details[:path] || "new_patient"
      refuse(result.reason, at[path])
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :existing, :create, :typed_failure, :refuse
  end
end
