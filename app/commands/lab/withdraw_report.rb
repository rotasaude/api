# O laudo ICP sai do pedido de assinatura (ADR 0037; B13, B56): só pelo
# sistema — interruptor desligado, falha definitiva ao assinar ou liberador
# desligado do laboratório. withdrawn nunca ganha data nem PDF (trigger) e os
# itens voltam à fila de liberação (o B54 deixa de valer). Trava requisição →
# laudo (a ordem do FinalizeReport). Chame dentro de uma transação.
module Lab
  module WithdrawReport
    module_function

    def call(report_id)
      report = LabReport.find_by(id: report_id)
      return nil unless report

      report.lab_requisition.lock!
      report.lock!
      return nil unless report.status == "pending_signature"

      report.update!(status: "withdrawn")
      DomainEvents.publish("lab_report.withdrawn", lab_report_id: report.id)
      report
    end
  end
end
