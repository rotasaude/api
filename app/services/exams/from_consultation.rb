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
    def cancel!(consultation:, sigtap_code:, by:)
      ExamOrder.joins(:consultation_exam_request)
               .where(consultation_exam_requests: { consultation_id: consultation.id, sigtap_code: sigtap_code })
               .where(status: Transition::FLOW["cancelled"][:from]).lock.to_a.each do |order|
        result = Transition.call(order: order, kind: "cancelled", actor_user: by, reason: "Cancelado por adendo da consulta")
        raise "cancelamento do exame recusado: #{result.reason}" if result.failure?
      end
    end
  end
end
