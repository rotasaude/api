# Sugestões (ADR 0040; spec §2 decisões 2, 8 e 9; plano, Desvios 5–7). O
# sistema sugere, um médico ou enfermeiro confirma (Task 11). Pacientes e
# pares validados sem paciente; só quem tem equipe atribuída recebe; nada
# repete por 365 dias; inscrito não recebe. Encerramento por problema
# resolvido vira SUGESTÃO, nunca encerramento. Extensão do Desvio 6
# (revisão final da branch): a inscrição ENCERRADA também segura a sugestão
# de inscrição da pessoa e da linha por 365 dias, contados de ended_at; o
# óbito, em qualquer linha, para sempre (nem inscrição nem encerramento).
# Só a sugestão: a inscrição manual (Enroll) segue possível.
module CareLines
  module Suggest
    BATCH = 500
    COOLDOWN = 365.days

    module_function

    def run(today: Time.zone.today)
      lines = CareLine.active_lines.order(:id).to_a
      return { created: 0, closures: 0 } if lines.empty?

      created = if every_patient?(lines)
                  Patient.in_batches(of: BATCH).sum { |batch| for_people(lines, Facts.patients(batch.pluck(:id)).values, today) }
                else
                  candidate_patient_ids(lines).each_slice(BATCH).sum { |ids| for_people(lines, Facts.patients(ids).values, today) }
                end
      created += Citizen.not_erased.verification_level_verified.where(patient_id: nil).in_batches(of: BATCH)
                        .sum { |batch| for_people(lines, Facts.citizens(batch.pluck(:id)).values, today) }
      { created: created, closures: closures!(lines, today) }
    end

    def for_patient(patient_id, today: Time.zone.today)
      lines = CareLine.active_lines.order(:id).to_a
      for_people(lines, Facts.patients([ patient_id ]).values, today) + closures!(lines, today, patient_ids: [ patient_id ])
    end

    def for_citizen(citizen_id, today: Time.zone.today)
      lines = CareLine.active_lines.order(:id).to_a
      citizen = Citizen.find_by(id: citizen_id)
      return 0 unless citizen

      people = citizen.patient_id ? Facts.patients([ citizen.patient_id ]).values : Facts.citizens([ citizen.id ]).values
      for_people(lines, people, today)
    end

    # Linha só por idade e sexo olha todos os pacientes (em lotes, sem carregar a cidade).
    def every_patient?(lines) = lines.any? { |line| line.eligibility["problems"].nil? && line.eligibility["declared"].nil? }

    # Por problema, só quem tem problema que casa; declaração, os pacientes
    # dos pares que declararam.
    def candidate_patient_ids(lines)
      ids = lines.filter_map { |line| line.eligibility["problems"] }.flat_map { |rules| Facts.problem_candidates(rules) }
      declared = CitizenDeclaredCondition.current.joins(:citizen).where.not(citizens: { patient_id: nil }).distinct.pluck("citizens.patient_id")
      (ids + declared).uniq
    end

    def for_people(lines, people, today)
      return 0 if people.empty?

      patient_ids = people.filter_map(&:patient_id)
      citizen_ids = people.filter_map(&:citizen_id)
      teams = TeamPopulation.patient_teams(patient_ids)
                            .merge(TeamPopulation.citizen_teams(Citizen.where(id: citizen_ids).select(:id, :neighborhood_id).to_a))
      enrolled = CareLineEnrollment.active_enrollments.where(patient_id: patient_ids).pluck(:patient_id, :care_line_id).to_set
      deceased, recently_ended = ended_holds(patient_ids)
      # Sugestão feita ao par antes de virar paciente vale para o paciente (365 dias).
      pair_patient = Citizen.where(patient_id: patient_ids).pluck(:id, :patient_id).to_h
      recent = CareLineSuggestion.where(patient_id: patient_ids).or(CareLineSuggestion.where(citizen_id: citizen_ids + pair_patient.keys))
                                 .where("status = 'pending' OR COALESCE(decided_at, created_at) >= ?", COOLDOWN.ago)
                                 .where.not(reason: "resolved_problem")
                                 .pluck(:patient_id, :citizen_id, :care_line_id).to_set { |p, c, l| [ p || pair_patient[c] || c, l ] }
      evidence = PatientProblem.active_problems.where(patient_id: patient_ids).pluck(:id, :patient_id, :terminology, :code)
                               .group_by { |row| row[1] }

      people.sum do |person|
        id = person.patient_id || person.citizen_id
        team_id = teams[id]
        next 0 unless team_id
        next 0 if deceased.include?(person.patient_id)

        lines.sum do |line|
          reason = Eligibility.match(line.eligibility, person, on: today)
          next 0 if reason.nil? || enrolled.include?([ person.patient_id, line.id ]) || recent.include?([ id, line.id ])
          next 0 if recently_ended.include?([ person.patient_id, line.id ])

          ref = reason == "problem" ? problem_ref(line, evidence.fetch(person.patient_id, [])) : nil
          create!(patient_id: person.patient_id, citizen_id: person.patient_id ? nil : person.citizen_id, care_line_id: line.id,
                  team_id: team_id, reason: reason, evidence_ref: ref)
        end
      end
    end

    # Extensão do Desvio 6 (uma consulta por lote): [pacientes com óbito em
    # qualquer linha, a qualquer tempo; pares [paciente, linha] com inscrição
    # encerrada nos últimos 365 dias, contados de ended_at].
    def ended_holds(patient_ids)
      cutoff = COOLDOWN.ago # uma leitura do relógio para o SQL e o Ruby
      rows = CareLineEnrollment.where(patient_id: patient_ids, status: "ended")
                               .where("ended_reason = 'death' OR ended_at >= ?", cutoff)
                               .pluck(:patient_id, :care_line_id, :ended_reason, :ended_at)
      [ rows.filter_map { |patient_id, _, reason, _| patient_id if reason == "death" }.to_set,
        rows.filter_map { |patient_id, line_id, _, ended_at| [ patient_id, line_id ] if ended_at >= cutoff }.to_set ]
    end

    def closures!(lines, _today, patient_ids: nil)
      problem_lines = lines.select { |line| line.eligibility["problems"] }
      return 0 if problem_lines.empty?

      scope = CareLineEnrollment.active_enrollments.where(care_line_id: problem_lines.map(&:id))
      scope = scope.where(patient_id: patient_ids) if patient_ids
      by_line = problem_lines.index_by(&:id)
      scope.in_batches(of: BATCH).sum { |batch| closure_batch(batch.to_a, by_line) }
    end

    def closure_batch(enrollments, by_line)
      people = Facts.patients(enrollments.map(&:patient_id))
      recent = CareLineSuggestion.where(enrollment_id: enrollments.map(&:id))
                                 .where("status = 'pending' OR COALESCE(decided_at, created_at) >= ?", COOLDOWN.ago)
                                 .pluck(:enrollment_id).to_set
      # Extensão do Desvio 6: óbito em qualquer linha também cala o encerramento.
      deceased = CareLineEnrollment.where(patient_id: enrollments.map(&:patient_id), status: "ended", ended_reason: "death")
                                   .distinct.pluck(:patient_id).to_set
      enrollments.sum do |enrollment|
        person = people[enrollment.patient_id]
        next 0 if person.nil? || recent.include?(enrollment.id) || deceased.include?(enrollment.patient_id)
        next 0 unless Eligibility.closure?(by_line.fetch(enrollment.care_line_id).eligibility, person)

        create!(patient_id: enrollment.patient_id, citizen_id: nil, care_line_id: enrollment.care_line_id, team_id: enrollment.team_id,
                reason: "resolved_problem", enrollment_id: enrollment.id, evidence_ref: "care_line_enrollment:#{enrollment.id}")
      end
    end

    def problem_ref(line, rows)
      rules = line.eligibility["problems"]
      row = rows.find { |_, _, terminology, code| Array(rules[terminology]).any? { |prefix| code.start_with?(prefix) } }
      row && "patient_problem:#{row[0]}"
    end

    # Cada sugestão no próprio savepoint: a corrida com o consumidor de
    # evento (mesma pessoa, mesma linha) cai no índice único e vira 0.
    # Sugestão de par: o par é relido sob FOR KEY SHARE (a mesma trava que a
    # FK do INSERT tomaria; a ordem de travas não muda). Apagado pela
    # exclusão LGPD ou rebaixado depois da leitura dos fatos → 0; a exclusão
    # em curso (FOR UPDATE no par) termina antes e a releitura a vê.
    # Sugestão de paciente: os pares dele, pela mesma trava e em ordem de id
    # (a do Erase); anonimizado depois da leitura → 0.
    def create!(**attrs)
      ApplicationRecord.transaction(requires_new: true) do
        next 0 if attrs[:citizen_id] && !live_pair?(attrs[:citizen_id])
        next 0 if attrs[:citizen_id].nil? && anonymized_patient?(attrs[:patient_id])

        suggestion = CareLineSuggestion.create!(attrs)
        DomainEvents.publish("care_line_suggestion.created", care_line_suggestion_id: suggestion.id)
        1
      end
    rescue ActiveRecord::RecordNotUnique
      0
    end

    def live_pair?(citizen_id) = Citizen.not_erased.verification_level_verified.where(id: citizen_id).lock("FOR KEY SHARE").exists?

    # O paciente não tem marca própria: o Erase apaga os pares (erased_at,
    # patient_id mantido) e anula só os DEMOGRAPHICS, que podem ser nulos em
    # qualquer paciente. Anonimizado = tem par apagado e nenhum par validado
    # vivo; sem par apagado (nunca excluído), segue. Pública: o Enroll faz a
    # mesma conferência (trava os pares: chame antes de travar o paciente).
    def anonymized_patient?(patient_id)
      pairs = Citizen.where(patient_id: patient_id).order(:id).lock("FOR KEY SHARE").pluck(:erased_at, :verification_level)
      pairs.any? { |erased_at, _| erased_at } && pairs.none? { |erased_at, level| erased_at.nil? && level == "verified" }
    end
    private_class_method :every_patient?, :candidate_patient_ids, :for_people, :ended_holds, :closures!, :closure_batch, :problem_ref, :create!,
                         :live_pair?
  end
end
