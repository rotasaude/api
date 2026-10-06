# "Não posso nesse horário" (ADR 0029 §6): antes do início, o cidadão cancela o
# horário marcado ou confirmado com um motivo da lista fixa e um período
# preferido; o pedido volta à fila marcado (reopened_reason citizen_reschedule),
# com a contagem, e o PRAZO NÃO MUDA. A nota (≤ 200) fica só no pedido: nunca em
# evento nem log.
#
# Travas na ordem global (Placement): unidade do horário FOR SHARE (aqui sem
# exigir unidade ativa: desistir de um horário vale mesmo em unidade desativada,
# como CancelByCitizen) → cidadão → horários vivos do pedido → pedido.
module Appointments
  module RequestReschedule
    MAX_NOTE = 200

    module_function

    def call(appointment:, reason_code:, note:, preferred_period:, now: Time.current)
      return Result.fail(:invalid_reason_code) unless AppointmentRequest::RESCHEDULE_REASONS.include?(reason_code)
      return Result.fail(:invalid_period) unless AppointmentRequest::PERIODS.include?(preferred_period)

      note = note.is_a?(String) ? note.strip.presence : nil
      return Result.fail(:note_too_long) if note && note.length > MAX_NOTE

      ApplicationRecord.transaction do
        HealthUnit.where(id: appointment.health_unit_id).lock("FOR SHARE").take!
        request = appointment.request
        Placement.lock_from_citizen!(request)
        appointment.reload
        next Result.fail(:not_reschedulable) unless reschedulable?(appointment, now)

        appointment.update!(status: "cancelled_by_citizen", cancel_reason: Appointment::RESCHEDULE_CANCEL_REASON,
                            reschedule_requested: true, ended_at: now)
        request.update!(status: "open", reopened_reason: "citizen_reschedule", reschedule_reason_code: reason_code,
                        reschedule_note: note, preferred_period: preferred_period,
                        reschedule_count: request.reschedule_count + 1)
        DomainEvents.publish("appointment.reschedule_requested", appointment_id: appointment.id, request_id: request.id)
        Result.ok(appointment: appointment)
      end
    end

    # Também decide `can_request_reschedule` em "Meus horários".
    def reschedulable?(appointment, now = Time.current)
      Appointment::LIVE.include?(appointment.status) && now < appointment.scheduled_at
    end
  end
end
