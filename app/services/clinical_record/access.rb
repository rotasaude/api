# app/services/clinical_record/access.rb
# Quem lê o prontuário (ADR 0031; spec §5): em contexto — atendimento in_care
# chamado pelo usuário, ou waiting na unidade de um vínculo ativo dele com CBO
# permitido, de um par VALIDADO do mesmo CPF —, com abertura justificada
# válida, ou ninguém. A recepção (sem health_professional) nunca lê. Toda
# leitura permitida deixa trilha (ClinicalRecord::Trail).
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
