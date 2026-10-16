# Retificação do resultado (ADR 0037; contrato §9, B8): novo exam_result com
# replaces_result_id (nada muda no anterior — sem UPDATE), evento
# result_rectified (o exame volta a `resulted` e perde a ciência),
# escalonamento por crítico (um por motivo, A31). Mesma trava e savepoint do
# RegisterResult. Nota #2: o substituído é sempre o vigente DESTE pedido
# (lido sob a trava; a validação do modelo é a rede). Valor, crítico e PDF
# nunca vão a log, evento (além do `critical`) ou mensagem de erro.
module Exams
  module RectifyResult
    module_function

    def call(order:, values:, critical:, file:, laboratory_name:, by_user:, by_provider:, now: Time.current)
      return Result.fail(:invalid_critical) unless [ true, false ].include?(critical)

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        order.lock!
        previous = ExamResult.current.find_by(exam_order_id: order.id)
        unless previous && %w[resulted acknowledged].include?(order.status)
          next result = Result.fail(:invalid_transition, details: { status: order.status })
        end
        next result = Result.fail(:missing_pdf) unless file&.content_type == "application/pdf"

        file.update!(consumed_at: now) unless file.consumed?
        moved = Transition.call(order: order, kind: "result_rectified", actor_user: by_user, actor_provider: by_provider,
                                event_payload: { critical: critical }, now: now)
        if moved.failure?
          result = moved
          raise ActiveRecord::Rollback
        end
        stored = ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order",
                                    source: previous.source, pdf_file: file, values: values.to_json, released_on: now.in_time_zone.to_date,
                                    laboratory_name: laboratory_name, critical: critical,
                                    exam_provider_id: by_provider&.id || order.exam_provider_id, registered_by_user: by_user,
                                    registered_by_provider: by_provider, replaces_result: previous)
        Escalate.call(order: order, reason: "critical", now: now) if critical
        order.association(:result).reset
        result = Result.ok(result: stored)
      end
      result
    end
  end
end
