# app/services/clinical_record/access.rb
# Quem lê o prontuário (ADR 0031; spec §5): em contexto — atendimento in_care
# chamado pelo usuário, ou waiting na unidade de um vínculo ativo dele com CBO
# permitido (geral; também o odontológico com dental_care utilizável, módulo 28), de
# um par VALIDADO do paciente (Patients::Pairs) —, com abertura justificada
# válida, ou ninguém. A recepção (sem health_professional) nunca lê. Toda
# leitura permitida deixa trilha (ClinicalRecord::Trail).
# Módulo 32a (ADR 0050; plano, Task 10): no atendimento `walk_in` da UPA a
# pessoa é o paciente (sem par do wpda): o contexto compara o `patient_id` do
# atendimento com o paciente, e os atendimentos abertos dele entram nas listas.
# A autora da consulta FINALIZADA lê a própria consulta a qualquer momento
# (for_consultation → :author; decisão do usuário 2026-10-09). A leitura
# administrativa do municipal_admin (:administrative) não passa por aqui.
module ClinicalRecord
  module Access
    Grant = Data.define(:kind, :opening, :reason) do
      def allowed? = kind != :denied
    end

    module_function

    def call(user:, patient:, attendance: nil, now: Time.current)
      return deny(:missing_role) unless user&.has_role?("health_professional")

      candidates = attendance ? [ attendance ] : open_attendances_of(patient)
      kind = waiting_kind
      return Grant.new(kind: :in_context, opening: nil, reason: nil) if candidates.any? { |a| in_context?(user, a, patient, kind) }

      opening = patient && ClinicalRecordOpening.valid_for(user_id: user.id, patient_id: patient.id, now: now)
                                                .order(created_at: :desc).first
      opening ? Grant.new(kind: :justified, opening: opening, reason: nil) : deny(:out_of_context)
    end

    # A consulta: a autora da finalizada lê sem contexto nem abertura (desde
    # que siga com health_professional); o resto (inclusive o rascunho) como call.
    def for_consultation(user:, consultation:, now: Time.current)
      return deny(:missing_role) unless user&.has_role?("health_professional")
      return Grant.new(kind: :author, opening: nil, reason: nil) if consultation.finalized? && consultation.author_user_id == user.id

      call(user: user, patient: consultation.patient, now: now)
    end

    # ADR 0035 (spec §5): a mesma regra sobre A PESSOA da linha do tempo
    # (Timeline::Person): em contexto por um atendimento aberto de um par dela,
    # ou abertura justificada válida do paciente OU de um par dela.
    def for_person(user:, person:, attendance: nil, now: Time.current)
      return deny(:missing_role) unless user&.has_role?("health_professional")

      candidates = attendance ? [ attendance ] : open_attendances_of_person(person)
      kind = waiting_kind
      in_context = candidates.any? { |a| person_of?(a, person) && in_context?(user, a, nil, kind) }
      return Grant.new(kind: :in_context, opening: nil, reason: nil) if in_context

      opening = ClinicalRecordOpening.valid_for_person(user_id: user.id, person: person, now: now).order(created_at: :desc).first
      opening ? Grant.new(kind: :justified, opening: opening, reason: nil) : deny(:out_of_context)
    end

    def open_attendances_of(patient)
      return [] unless patient

      Attendance.open_attendances.where(citizen_id: Patients::Pairs.of(patient).select(:id))
                .or(open_walk_ins(patient.id)).includes(:citizen).to_a
    end

    def open_attendances_of_person(person)
      scope = Attendance.open_attendances.where(citizen_id: person.citizen_ids)
      scope = scope.or(open_walk_ins(person.patient_id)) if person.patient_id
      scope.includes(:citizen).to_a
    end

    def open_walk_ins(patient_id) = Attendance.open_attendances.where(origin_kind: "walk_in", patient_id: patient_id)

    # A pessoa do atendimento: o par no 13, o paciente no walk_in.
    def person_of?(attendance, person)
      return person.citizen_ids.include?(attendance.citizen_id) unless attendance.walk_in?

      attendance.patient_id.present? && attendance.patient_id == person.patient_id
    end

    # Módulo 28: com dental_care utilizável (lido fora da transação), o
    # vínculo odontológico também põe em contexto quem espera na unidade.
    def waiting_kind = DentalCare::Gate.usable?(Current.city) ? :any : "general"

    def in_context?(user, attendance, patient, kind)
      if attendance.walk_in?
        return false if patient && attendance.patient_id != patient.id
      else
        citizen = attendance.citizen
        return false unless citizen.verification_level_verified?
        return false if patient && !pair_of?(citizen, patient)
      end

      case attendance.status
      when "in_care" then attendance.called_by_user_id == user.id
      when "waiting"
        ApplicationRecord.transaction do
          Consultations::Authorization.link_for(user: user, health_unit_id: attendance.health_unit_id, kind: kind).first == :ok
        end
      else false
      end
    end

    # O par do paciente (como Patients::Pairs.of): ligado a ele ou, só quando
    # ele tem CPF, do mesmo CPF — paciente sem CPF (24a) nunca casa por CPF nulo.
    def pair_of?(citizen, patient)
      citizen.patient_id == patient.id || (patient.cpf.present? && citizen.cpf == patient.cpf)
    end

    def deny(reason) = Grant.new(kind: :denied, opening: nil, reason: reason)
    private_class_method :open_attendances_of, :open_attendances_of_person, :open_walk_ins, :person_of?, :waiting_kind,
                         :in_context?, :pair_of?, :deny
  end
end
