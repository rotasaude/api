# Ciclo do pedido (ADR 0019): abrir a partir do desfecho, encerrar e reabrir.
# Chamado DENTRO da transação de quem muda o estado.
module AppointmentRequests
  module Lifecycle
    module_function

    # Módulo 32a (ADR 0050; plano, Desvio 2): o walk_in da UPA não tem o par
    # do wpda (citizen_id nulo) e o pedido do 17 é do par — não abre pedido; a
    # volta à UBS é a lista de retornos da urgência (Urgency::CounterReferrals).
    def open_for!(attendance, outcome:, unit:)
      return nil if attendance.walk_in?

      target = outcome == "return" ? attendance.health_unit : unit
      return nil if target.nil? || !%w[return referred].include?(outcome)

      request = AppointmentRequest.create!(
        origin_attendance: attendance, citizen: attendance.citizen, root_triage: attendance.root_triage,
        origin_unit: attendance.health_unit, target_unit: target,
        kind: outcome == "return" ? "return" : "referral", note: attendance.referral_note,
        appointment_type_key: "retorno", priority: "routine",
        due_on: Time.zone.today + AppointmentRequest::DUE_IN_DAYS
      )
      DomainEvents.publish("appointment_request.created", appointment_request_id: request.id,
                                                          origin_attendance_id: attendance.id,
                                                          target_unit_id: target.id, kind: request.kind)
      request
    end

    def close!(request, reason:, by: nil, dismiss_reason: nil)
      request.update!(status: "closed", closed_reason: reason, closed_by_user: by, closed_at: Time.current,
                      dismiss_reason: dismiss_reason)
      DomainEvents.publish("appointment_request.closed", appointment_request_id: request.id, closed_reason: reason)
    end

    def reopen!(request, reason:)
      request.update!(status: "open", reopened_reason: reason)
    end
  end
end
