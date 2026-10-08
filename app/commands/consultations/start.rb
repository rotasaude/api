# app/commands/consultations/start.rb
# Iniciar a consulta (ADR 0031; spec §4): interruptor utilizável; atendimento
# in_care chamado por quem inicia; CBO permitido; par validado; paciente
# resolvido pelo CPF (Patients::Resolve). Uma por atendimento: o lock do
# atendimento serializa duas abas do mesmo profissional; o índice único é a
# última palavra. Ordem de travas: atendimento → CPF → par → paciente.
module Consultations
  class Start
    def self.call(attendance:, by:, city: Current.city)
      return Result.fail(:feature_disabled) unless ClinicalRecord::Gate.usable?(city)

      ApplicationRecord.transaction do
        attendance.lock!
        status, link = Authorization.link_for(user: by, health_unit_id: attendance.health_unit_id)
        next Result.fail(status) unless status == :ok
        next Result.fail(:not_in_care) unless attendance.status == "in_care"
        next Result.fail(:not_caller) unless attendance.called_by_user_id == by.id

        existing = Consultation.find_by(attendance_id: attendance.id)
        next Result.fail(:already_exists, details: { consultation_id: existing.id }) if existing

        resolved = Patients::Resolve.call(attendance.citizen)
        next resolved if resolved.failure?

        consultation = Consultation.create!(
          attendance: attendance, patient: resolved.payload[:patient], author_user: by, professional_link: link,
          cbo_code: link.cbo_code, status: "draft", care_type: CareType.suggest(attendance), started_at: Time.current
        )
        DomainEvents.publish("consultation.started", consultation_id: consultation.id, attendance_id: attendance.id)
        Result.ok(consultation: consultation)
      end
    end
  end
end
