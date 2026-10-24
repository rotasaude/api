# O que a elegibilidade precisa de cada pessoa, decifrado em lote (consultas
# constantes por lote): nascimento e sexo (paciente ou par), identidade de
# gênero e condições declaradas (pares validados), problemas ativos e
# resolvidos. Nada é gravado.
module CareLines
  module Facts
    module_function

    def patients(ids)
      ids = ids.uniq
      return {} if ids.empty?

      problems = PatientProblem.where(patient_id: ids).pluck(:patient_id, :terminology, :code, :status, :id, :created_at).group_by(&:first)
      activated = last_activation(problems.values.flatten(1).select { |r| r[3] == "active" })
      pairs = Citizen.not_erased.verification_level_verified.where(patient_id: ids).order(updated_at: :desc).to_a.group_by(&:patient_id)
      declared = declared_by_citizen(pairs.values.flatten.map(&:id))
      Patient.where(id: ids).to_a.to_h do |patient|
        linked = pairs.fetch(patient.id, [])
        rows = problems.fetch(patient.id, [])
        [ patient.id, Person.new(patient_id: patient.id, birth_date: date(patient.birth_date), sex: patient.sex,
                                 gender_identity: linked.first&.gender_identity,
                                 problems: rows.select { |r| r[3] == "active" }.map { |r| r[1, 2] },
                                 problem_since: rows.select { |r| r[3] == "active" }.to_h { |r| [ r[1, 2], activated.fetch(r[4]) ] },
                                 resolved_problems: rows.select { |r| r[3] == "resolved" }.map { |r| r[1, 2] },
                                 declared: linked.flat_map { |c| declared.fetch(c.id, []) }.uniq) ]
      end
    end

    # Pares validados sem paciente, uma pessoa por CPF (revisão final, Minor
    # 1): o par cujo CPF já tem paciente fica de fora (a pessoa é o paciente;
    # o Resolve os ligaria); entre pares sem paciente do mesmo CPF, só o mais
    # antigo (created_at, id) — o mesmo critério do território (P18). Duas
    # consultas a mais por lote, contra a cidade toda (o mais antigo pode
    # estar em outro lote).
    def citizens(ids)
      ids = ids.uniq
      return {} if ids.empty?

      declared = declared_by_citizen(ids)
      rows = Citizen.not_erased.verification_level_verified.where(id: ids, patient_id: nil).to_a
      kept = one_per_cpf(rows.map { |citizen| [ citizen.id, citizen.cpf ] })
      rows.select { |citizen| kept.include?(citizen.id) }.to_h do |citizen|
        [ citizen.id, Person.new(citizen_id: citizen.id, birth_date: date(citizen.birth_date), sex: citizen.sex,
                                 gender_identity: citizen.gender_identity, declared: declared.fetch(citizen.id, [])) ]
      end
    end

    # Pacientes com QUALQUER inscrição encerrada por óbito, em qualquer linha
    # e a qualquer tempo (P19/P21), OU com o cadastro individual saído por
    # óbito (módulo 24a, contrato §9) — uma consulta (UNION). A marca única do
    # óbito: o Suggest a usa para calar sugestões, a população da prévia para
    # tirar a pessoa do denominador. `ended_reason` e `exit_reason` ficam em
    # claro (enums com CHECK). Não depende do interruptor: o óbito gravado
    # continua óbito se o cadastro for desligado depois.
    # Os ids vão num bind só (= ANY($1::uuid[])), fora do texto do SQL: o
    # SQL não cresce com a equipe (revisão final do 24a, M2).
    def deceased(patient_ids)
      return Set.new if patient_ids.empty?

      sql = <<~SQL
        SELECT patient_id FROM care_line_enrollments WHERE patient_id = ANY($1::uuid[]) AND status = 'ended' AND ended_reason = 'death'
        UNION
        SELECT patient_id FROM individual_registrations WHERE patient_id = ANY($1::uuid[]) AND exit_reason = 'death'
      SQL
      ApplicationRecord.connection.select_values(sql, "CareLines::Facts.deceased", [ uuid_array(patient_ids) ]).to_set
    end

    # Bind de uma lista de uuids como um array do Postgres ($n::uuid[]).
    def uuid_array(ids)
      ActiveRecord::Relation::QueryAttribute.new("ids", "{#{ids.join(',')}}", ActiveRecord::Type::String.new)
    end

    # Pacientes com problema ativo que casa por prefixo (uma consulta).
    # `among:` cruza no SQL com os ids já escolhidos (a prévia: só a equipe).
    def problem_candidates(rules, among: nil)
      clauses = rules.flat_map do |terminology, prefixes|
        prefixes.map { |prefix| PatientProblem.sanitize_sql([ "(terminology = ? AND code LIKE ?)", terminology, "#{prefix}%" ]) }
      end
      return [] if clauses.empty?

      scope = PatientProblem.active_problems.where(clauses.join(" OR "))
      scope = scope.where(patient_id: among) if among
      scope.distinct.pluck(:patient_id)
    end

    # Ids dos pares (Citizen) que representam a pessoa: sem paciente com o
    # mesmo CPF e o mais antigo do CPF. Recebe tuplas [id, cpf] (pluck).
    # Público para a validade do cadastro (TerritoryRegistry::RegistryStatus),
    # que não decifra o resto do par.
    def one_per_cpf(pairs)
      return Set.new if pairs.empty?

      cpfs = pairs.map(&:last).uniq
      with_patient = Patient.where(cpf: cpfs).pluck(:cpf).to_set
      oldest = Citizen.not_erased.verification_level_verified.where(patient_id: nil, cpf: cpfs).order(:created_at, :id)
                      .pluck(:cpf, :id).each_with_object({}) { |(cpf, id), out| out[cpf] ||= id }
      pairs.filter_map { |id, cpf| id if !with_patient.include?(cpf) && oldest[cpf] == id }.to_set
    end

    def declared_by_citizen(citizen_ids)
      return {} if citizen_ids.empty?

      CitizenDeclaredCondition.current.where(citizen_id: citizen_ids).to_a.group_by(&:citizen_id)
                              .transform_values { |rows| rows.map(&:condition).uniq - %w[none] }
    end

    # Dia (da cidade) em que cada problema ativo passou a estar ativo pela
    # última vez: o evento added/reactivated mais recente (uma consulta em
    # lote); sem evento, o created_at do problema (já lido). onset_corrected
    # não conta (corrige o início, não ativa).
    def last_activation(active_rows)
      return {} if active_rows.empty?

      events = PatientProblemEvent.where(patient_problem_id: active_rows.map { |r| r[4] }, kind: %w[added reactivated], status_after: "active")
                                  .group(:patient_problem_id).maximum(:created_at)
      active_rows.to_h { |r| [ r[4], (events[r[4]] || r[5]).in_time_zone.to_date ] }
    end

    def date(value)
      value.present? ? Date.iso8601(value) : nil
    rescue Date::Error
      nil
    end
    private_class_method :declared_by_citizen, :last_activation, :date
  end
end
