# Saída com motivo (contrato §1 e §4): uma vez; a nota (opcional, até 500)
# cifrada. A sugestão de encerramento pendente da inscrição fica aceita por
# quem encerrou.
#
# Óbito e mudança (§11 T4, decisão da coordenação) fecham na mesma transação
# o pedido care_line VIVO criado pela própria inscrição (o reaproveitado de
# outro tipo nunca): o horário vivo dele é cancelado como a exclusão LGPD
# cancela (cancelled_by_citizen, texto fixo, evento só com ids) e o pedido
# fecha como `dismissed` com o texto fixo do motivo (Lifecycle.close!, evento
# do 17).
#
# Ordem de travas: unidade de destino do pedido (FOR SHARE) → cidadão do
# pedido (FOR NO KEY UPDATE) → sugestões de encerramento → inscrição →
# horários vivos do pedido → pedido. É a global (unidade → cidadão → horários
# → pedido, Appointments::Placement e Citizens::Erase) com as travas da
# inscrição entre o cidadão e os horários, como em OpenAppointmentRequest
# (unidade → cidadão → inscrição) e no Desvio 8 (sugestões → inscrição). O
# pedido é lido antes das travas; relido depois da inscrição, se mudou (um
# Drain o levou para outra unidade, ou um "Agendar" o criou) a transação
# recomeça com a unidade nova na frente.
module CareLines
  module EndEnrollment
    module_function

    CLOSES_REQUEST = %w[death moved].freeze
    REQUEST_DISMISS_REASONS = { "death" => "Inscrição na linha de cuidado encerrada: óbito",
                                "moved" => "Inscrição na linha de cuidado encerrada: mudança" }.freeze
    APPOINTMENT_CANCEL_REASON = "Inscrição na linha de cuidado encerrada".freeze
    MAX_ATTEMPTS = 3

    class RequestChanged < StandardError; end

    def call(enrollment:, reason:, note:, by:)
      return Result.fail(:invalid_reason) unless Catalog::END_REASONS.include?(reason)

      text = note.is_a?(String) ? note.strip.presence : nil
      return Result.fail(:too_long, details: { field: "note" }) if text && text.length > Catalog::TEXT_MAX

      attempts = 0
      begin
        attempts += 1
        ApplicationRecord.transaction do
          request = CLOSES_REQUEST.include?(reason) ? own_live_request(enrollment) : nil
          if request
            HealthUnit.where(id: request.target_unit_id).lock("FOR SHARE").to_a
            Citizen.lock("FOR NO KEY UPDATE").find(request.citizen_id)
          end
          CareLineSuggestion.pending_suggestions.where(enrollment_id: enrollment.id).order(:id).lock.to_a
          enrollment.lock!
          next Result.fail(:invalid_transition) unless enrollment.active?

          if CLOSES_REQUEST.include?(reason)
            current = own_live_request(enrollment)
            raise RequestChanged unless current&.id == request&.id && current&.target_unit_id == request&.target_unit_id
          end

          end!(enrollment, reason: reason, note: text, by: by)
          close_request!(request, reason: reason, by: by) if request
          Result.ok(enrollment: enrollment)
        end
      rescue RequestChanged
        retry if attempts < MAX_ATTEMPTS
        raise
      end
    end

    # Quem chama trava as sugestões de encerramento e a inscrição, nessa
    # ordem, e confere que está ativa.
    def end!(enrollment, reason:, note:, by:)
      enrollment.update!(status: "ended", ended_reason: reason, ended_note: note, ended_at: Time.current, ended_by_user: by)
      CareLineSuggestion.pending_suggestions.where(enrollment_id: enrollment.id).find_each do |closure|
        AcceptSuggestion.decide!(closure, by)
      end
      DomainEvents.publish("care_line_enrollment.ended", care_line_enrollment_id: enrollment.id, user_id: by.id)
    end

    def own_live_request(enrollment)
      AppointmentRequest.live_requests.where(kind: "care_line", origin_care_line_enrollment_id: enrollment.id).order(:id).first
    end

    # Horários vivos antes do pedido (Lapse/Confirm/CancelByCitizen travam o
    # horário e depois o pedido).
    def close_request!(request, reason:, by:)
      now = Time.current
      Appointment.live.where(request_id: request.id).order(:id).lock.each do |appointment|
        appointment.update!(status: "cancelled_by_citizen", cancel_reason: APPOINTMENT_CANCEL_REASON, ended_at: now)
        DomainEvents.publish("appointment.cancelled", appointment_id: appointment.id, by: "care_line")
      end
      request.lock!
      AppointmentRequests::Lifecycle.close!(request, reason: "dismissed", by: by, dismiss_reason: REQUEST_DISMISS_REASONS.fetch(reason))
    end
    private_class_method :own_live_request, :close_request!
  end
end
