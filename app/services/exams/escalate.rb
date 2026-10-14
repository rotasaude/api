# Leva o exame à fila da equipe (ADR 0036; spec §5): no máximo um
# escalonamento por motivo (A31: overdue | critical | unlinked_requester);
# escalated_at guarda o PRIMEIRO; não muda o status. Trava o pedido por dentro
# (ruling da Task 13; inócuo se o chamador já travou).
module Exams
  module Escalate
    module_function

    def call(order:, reason:, now: Time.current)
      raise ArgumentError, "motivo fora da lista: #{reason}" unless ExamOrderEvent::ESCALATION_REASONS.include?(reason)

      ApplicationRecord.transaction(requires_new: true) do
        order.lock!
        next Result.ok(order: order, escalated: false) if escalated_for?(order, reason)

        ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: reason, occurred_at: now)
        order.update!(escalated_at: now) unless order.escalated?
        DomainEvents.publish("exam_order.escalated", exam_order_id: order.id, reason: reason)
        Result.ok(order: order, escalated: true)
      end
    end

    def escalated_for?(order, reason)
      ExamOrderEvent.exists?(exam_order_id: order.id, kind: "escalated", escalation_reason: reason)
    end
    private_class_method :escalated_for?
  end
end
