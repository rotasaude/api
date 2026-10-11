# app/services/clinical_record/access.rb
# Quem lê o prontuário (ADR 0031; spec §5): em contexto — atendimento in_care
# chamado pelo usuário, ou waiting na unidade de um vínculo ativo dele com CBO
# permitido, de um par VALIDADO do mesmo CPF —, com abertura justificada
# válida, ou ninguém. A recepção (sem health_professional) nunca lê. Toda
# leitura permitida deixa trilha (ClinicalRecord::Trail).
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
      return Grant.new(kind: :in_context, opening: nil, reason: nil) if candidates.any? { |a| in_context?(user, a, patient) }

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

      candidates = attendance ? [ attendance ] : Attendance.open_attendances.where(citizen_id: person.citizen_ids).includes(:citizen).to_a
      in_context = candidates.any? { |a| person.citizen_ids.include?(a.citizen_id) && in_context?(user, a, nil) }
      return Grant.new(kind: :in_context, opening: nil, reason: nil) if in_context

      opening = ClinicalRecordOpening.valid_for_person(user_id: user.id, person: person, now: now).order(created_at: :desc).first
      opening ? Grant.new(kind: :justified, opening: opening, reason: nil) : deny(:out_of_context)
    end

    def open_attendances_of(patient)
      return [] unless patient

      pairs = Citizen.not_erased.verification_level_verified.where(cpf: patient.cpf).select(:id)
      Attendance.open_attendances.where(citizen_id: pairs).includes(:citizen).to_a
    end

    def in_context?(user, attendance, patient)
      citizen = attendance.citizen
      return false unless citizen.verification_level_verified?
      return false if patient && citizen.cpf != patient.cpf

      case attendance.status
      when "in_care" then attendance.called_by_user_id == user.id
      when "waiting"
        ApplicationRecord.transaction do
          Consultations::Authorization.link_for(user: user, health_unit_id: attendance.health_unit_id).first == :ok
        end
      else false
      end
    end

    def deny(reason) = Grant.new(kind: :denied, opening: nil, reason: reason)
    private_class_method :open_attendances_of, :in_context?, :deny
  end
end
