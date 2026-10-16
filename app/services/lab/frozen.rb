# Laudo ICP congelado (B54): o conteúdo do laudo pending_signature é o que
# vai ser assinado; enquanto ele espera, o item não recebe valor nem escolha
# e não entra em outra liberação.
module Lab
  module Frozen
    module_function

    # Ids (subconsulta) dos itens cobertos por laudo pending_signature.
    def item_ids
      LabReportItem.joins(:lab_report).where(lab_reports: { status: "pending_signature" }).select(:lab_requisition_item_id)
    end

    def item?(item_or_ids)
      ids = Array(item_or_ids).map { |i| i.respond_to?(:id) ? i.id : i }
      LabReportItem.joins(:lab_report).where(lab_requisition_item_id: ids, lab_reports: { status: "pending_signature" }).exists?
    end
  end
end
