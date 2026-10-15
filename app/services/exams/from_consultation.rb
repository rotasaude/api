# Ligação com o 19a (spec §4): o pedido `requested` da consulta vira
# exam_order (origem consultation, solicitante = autora, unidade do
# atendimento), sem exigir o catálogo (Desvio 8). Dentro do savepoint da
# finalização/adendo: falha levanta e desfaz tudo. A exceção (OpenFailed, ou
# RuntimeError no cancelamento) PROPAGA por Consultations::Finalize.call e
# Consultations::AddAddendum.call: aparece como 500, não como Result de falha.
module Exams
  module FromConsultation
    class OpenFailed < StandardError; end

    module_function

    def open!(consultation:, requests:)
      unit = consultation.attendance.health_unit
      requests.each do |request|
        result = Open.call(patient: consultation.patient, sigtap_code: request.sigtap_code, priority: request.priority,
                           unit: unit, origin: "consultation", requester_user: consultation.author_user,
                           created_by: consultation.author_user, cid10: request.cid10_justification,
                           consultation_exam_request: request, sigtap_competence: request.sigtap_competence,
                           require_catalog: false)
        raise OpenFailed, "abertura do exame recusada: #{result.reason}" if result.failure?
      end
    end

    # Cancela o exame vivo do pedido retirado, se ainda sem resultado
    # (resulted/acknowledged/denied/cancelled ficam como estão).
    # Passa por Steps.cancel (ordem de trava requisição → item → pedido, E2): item
    # pendente da requisição do laboratório é cancelado junto; item digitado ou
    # liberado deixa o exame como está (o adendo segue).
    def cancel!(consultation:, sigtap_code:, by:)
      ids = ExamOrder.joins(:consultation_exam_request)
                     .where(consultation_exam_requests: { consultation_id: consultation.id, sigtap_code: sigtap_code })
                     .where(status: Transition::FLOW["cancelled"][:from]).order(:id).pluck(:id)
      ids.each do |id|
        result = Steps.cancel(order: ExamOrder.find(id), reason: "Cancelado por adendo da consulta", actor_user: by)
        next if result.ok?
        next if result.reason == :invalid_transition && LabRequisitionItem.exists?(exam_order_id: id, status: %w[typed released])

        raise "cancelamento do exame recusado: #{result.reason}"
      end
    end
  end
end
