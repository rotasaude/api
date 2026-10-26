# Consumidor de territory_registration.exited (contrato §14 L30). Óbito: as
# inscrições ATIVAS da pessoa encerram por `death` (EndEnrollment: aceita a
# sugestão de encerramento ligada e fecha o pedido vivo da inscrição) e as
# sugestões PENDENTES dela, em todas as linhas, ficam dispensadas com o
# motivo fixo. "A pessoa" é a do 23: o paciente e os pares validados dele
# (Patients::Pairs.of — ligados ou com o CPF dele, como o Enroll). Mudança:
# nada (a equipe da inscrição decide, L22). O motivo da saída vem do
# cadastro (o payload só tem ids).
#
# Travas na ordem global do 23 (Citizens::Erase, EndEnrollment): unidades de
# destino dos pedidos vivos das inscrições (FOR SHARE) → cidadãos desses
# pedidos (FOR NO KEY UPDATE), ambos por id → sugestões sem inscrição ativa
# (DismissSuggestion) → cada inscrição (EndEnrollment, que retrava as mesmas
# unidades/cidadãos já nossos, depois as sugestões de encerramento e a
# inscrição). Um Drain que mude a unidade do pedido no meio cai no retry do
# EndEnrollment, dentro desta transação (raro; Deadlocked → retry_on do job).
#
# As recusas dos comandos (invalid_transition) são ignoradas de propósito: só
# acontecem quando outra decisão chegou antes sob a trava (sugestão já
# decidida, inscrição já encerrada) — o estado final é o mesmo que o óbito
# pede. Idempotente: o IdempotentConsumer deduplica o evento, e só o que
# ainda está ativo/pendente muda. `by:` = quem registrou a saída (user_id do
# evento): nenhum dos dois comandos exige papel clínico. Não depende do
# interruptor care_lines: o óbito gravado vale sempre (como
# CareLines::Facts.deceased).
module CareLines
  class RegistrationExitedJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    DISMISS_REASON = "Óbito registrado no cadastro territorial".freeze

    def handle(registration_id:, user_id:, **)
      registration = IndividualRegistration.includes(:patient).find_by(id: registration_id)
      return unless registration&.exit_reason == "death"

      by = User.find(user_id)
      patient = registration.patient
      enrollments = CareLineEnrollment.active_enrollments.where(patient_id: patient.id).order(:id).to_a
      lock_requests!(enrollments.map(&:id))
      pending_suggestions(patient, enrollments.map(&:id)).each do |suggestion|
        DismissSuggestion.call(suggestion: suggestion, reason: DISMISS_REASON, by: by)
      end
      enrollments.each { |enrollment| EndEnrollment.call(enrollment: enrollment, reason: "death", note: nil, by: by) }
    end

    private

    # O começo da ordem global: unidade → cidadão dos pedidos vivos que o
    # EndEnrollment vai fechar.
    def lock_requests!(enrollment_ids)
      return if enrollment_ids.empty?

      requests = AppointmentRequest.live_requests.where(kind: "care_line", origin_care_line_enrollment_id: enrollment_ids)
                                   .pluck(:target_unit_id, :citizen_id)
      HealthUnit.where(id: requests.map(&:first).uniq).order(:id).lock("FOR SHARE").to_a
      Citizen.where(id: requests.map(&:last).uniq).order(:id).lock("FOR NO KEY UPDATE").to_a
    end

    # As pendentes do paciente e dos pares dele, menos as de encerramento de
    # inscrição ativa (o EndEnrollment as aceita, na ordem dele).
    def pending_suggestions(patient, active_enrollment_ids)
      scope = CareLineSuggestion.pending_suggestions
      mine = scope.where(patient_id: patient.id).or(scope.where(citizen_id: Patients::Pairs.of(patient).select(:id)))
      mine = mine.where(enrollment_id: nil).or(mine.where.not(enrollment_id: active_enrollment_ids)) if active_enrollment_ids.any?
      mine.order(:id).to_a
    end
  end
end
