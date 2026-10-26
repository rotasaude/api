# Consumidor de territory_registration.exited (contrato §14 L30). Óbito: as
# inscrições ATIVAS da pessoa encerram por `death` (EndEnrollment: aceita a
# sugestão de encerramento ligada e fecha o pedido vivo da inscrição) e as
# sugestões PENDENTES dela, em todas as linhas (as do par validado também),
# ficam dispensadas com o motivo fixo. Mudança: nada (a equipe da inscrição
# decide, L22). O motivo da saída vem do cadastro (o payload só tem ids).
#
# Ordem de travas do 23 (Desvio 8, sugestões → inscrição): primeiro as
# sugestões sem inscrição ativa (DismissSuggestion), depois cada inscrição
# (EndEnrollment trava unidade → cidadão → sugestões de encerramento →
# inscrição). Idempotente: o IdempotentConsumer deduplica o evento, e só o
# que ainda está ativo/pendente muda. `by:` = quem registrou a saída
# (user_id do evento): nenhum dos dois comandos exige papel clínico. Não
# depende do interruptor care_lines: o óbito gravado vale sempre (como
# CareLines::Facts.deceased).
module CareLines
  class RegistrationExitedJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    DISMISS_REASON = "Óbito registrado no cadastro territorial".freeze

    def handle(registration_id:, user_id:, **)
      registration = IndividualRegistration.find_by(id: registration_id)
      return unless registration&.exit_reason == "death"

      by = User.find(user_id)
      patient_id = registration.patient_id
      enrollments = CareLineEnrollment.active_enrollments.where(patient_id: patient_id).order(:id).to_a
      pending_suggestions(patient_id, enrollments.map(&:id)).each do |suggestion|
        DismissSuggestion.call(suggestion: suggestion, reason: DISMISS_REASON, by: by)
      end
      enrollments.each { |enrollment| EndEnrollment.call(enrollment: enrollment, reason: "death", note: nil, by: by) }
    end

    private

    # As pendentes do paciente e dos pares dele, menos as de encerramento de
    # inscrição ativa (o EndEnrollment as aceita, na ordem dele).
    def pending_suggestions(patient_id, active_enrollment_ids)
      scope = CareLineSuggestion.pending_suggestions
      mine = scope.where(patient_id: patient_id).or(scope.where(citizen_id: Citizen.where(patient_id: patient_id).select(:id)))
      mine = mine.where(enrollment_id: nil).or(mine.where.not(enrollment_id: active_enrollment_ids)) if active_enrollment_ids.any?
      mine.order(:id).to_a
    end
  end
end
