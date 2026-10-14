# Leva o exame à fila da equipe (ADR 0036; spec §5): uma vez só; não muda
# o status. Quem chama trava o pedido.
module Exams
  module Escalate
    module_function

    def call(order:, reason:, now: Time.current)
      raise ArgumentError, "motivo fora da lista: #{reason}" unless ExamOrderEvent::ESCALATION_REASONS.include?(reason)
      return Result.ok(order: order, escalated: false) if order.escalated?

      ApplicationRecord.transaction(requires_new: true) do
        ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: reason, occurred_at: now)
        order.update!(escalated_at: now)
        DomainEvents.publish("exam_order.escalated", exam_order_id: order.id, reason: reason)
      end
      Result.ok(order: order, escalated: true)
    end
  end
end
