# A única porta do cache da situação (ADR 0036; Desvios 6, 7 e 11): valida
# pela tabela, grava o evento (com o prazo da etapa que fecha) e atualiza o
# pedido com a etapa seguinte e o prazo dela, num savepoint. Trava o pedido
# por dentro, ANTES de conferir a tabela (ruling da Task 13): nenhum chamador
# decide sobre um status velho (ex.: resultado em pedido já cancelado). Se o
# chamador já travou, a trava de novo é inócua (mesma transação).
module Exams
  module Transition
    FLOW = {
      "authorized" => { from: %w[awaiting_authorization], to: "awaiting_schedule" },
      "denied" => { from: %w[awaiting_authorization], to: "denied" },
      # ADR 0037: a recoleta do laboratório reabre a coleta; as rotas da unidade e do portal
      # recusam `collected` em Steps.schedule.
      "scheduled" => { from: %w[awaiting_schedule scheduled collected], to: "scheduled" },
      "collected" => { from: %w[scheduled], to: "collected" },
      "resulted" => { from: %w[scheduled collected], to: "resulted" },
      "acknowledged" => { from: %w[resulted], to: "acknowledged" },
      # ADR 0037: laudo retificado volta à ciência.
      "result_rectified" => { from: %w[resulted acknowledged], to: "resulted" },
      "cancelled" => { from: %w[awaiting_authorization awaiting_schedule scheduled collected], to: "cancelled" }
    }.freeze
    NEXT_STAGE = { "awaiting_authorization" => "authorize", "awaiting_schedule" => "schedule", "scheduled" => "collect",
                   "collected" => "result", "resulted" => "acknowledge" }.freeze
    REASON_REQUIRED = %w[denied cancelled].freeze

    module_function

    def call(order:, kind:, actor_user: nil, actor_provider: nil, reason: nil, changes: {}, event_payload: {}, now: Time.current)
      flow = FLOW.fetch(kind)
      reason = reason.is_a?(String) ? reason.strip : nil
      ApplicationRecord.transaction(requires_new: true) do
        order.lock!
        next Result.fail(:invalid_transition, details: { status: order.status }) unless flow[:from].include?(order.status)
        next Result.fail(:reason_required) if REASON_REQUIRED.include?(kind) && reason.to_s.length < 3
        next Result.fail(:reason_too_long) if reason.to_s.length > 500

        to = flow[:to]
        stage = NEXT_STAGE[to]
        provider_id = changes.fetch(:exam_provider_id, order.exam_provider_id)
        due = stage && now.in_time_zone.to_date + Deadlines.days(stage: stage, sigtap_code: order.sigtap_code,
                                                                provider_id: provider_id, priority: order.priority)
        ExamOrderEvent.create!(exam_order: order, kind: kind, actor_user: actor_user, actor_provider: actor_provider,
                               reason: reason.presence, closed_stage_due_on: order.stage_due_on, occurred_at: now)
        order.update!(changes.merge(status: to, status_changed_at: now, stage: stage, stage_opened_at: stage && now,
                                    stage_due_on: due))
        DomainEvents.publish("exam_order.#{kind}", exam_order_id: order.id, **event_payload)
        Result.ok(order: order)
      end
    end
  end
end
