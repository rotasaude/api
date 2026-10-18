# Revisão (spec §5.6; Desvio 8; C-E21): na abertura do bloqueio, os itens do
# aparelho cujo exame tem o analito e cujo laudo saiu depois do INÍCIO
# (started_at) da última corrida aceita (aprovada ou com aviso) com o analito
# no aparelho — ou, sem ela, da primeira referência aceita — entram pendentes.
# Laudo ICP ainda pending_signature (criado depois do marco) também entra: ele
# vai sair na assinatura, e a finalização do ICP não consulta o CIQ (recusar
# descartaria uma assinatura já feita). Só leitura do 21b; cria linhas de revisão.
module Lab
  module Qc
    module Reviews
      module_function

      def enqueue!(block, run:)
        since = since_for(block, run)
        versions = LabExamVersion.where(lab_instrument_id: block.lab_instrument_id)
                                 .where("analytes @> ?::jsonb", [ { key: block.analyte_key } ].to_json).select(:id)
        out = LabReportItem.joins(:lab_report)
        released = out.where(lab_reports: { status: %w[released rectified] }).where("lab_reports.released_at > ?", since)
        signing = out.where(lab_reports: { status: "pending_signature" }).where("lab_reports.created_at > ?", since)
        item_ids = released.or(signing).where(lab_requisition_item_id: LabRequisitionItem.where(lab_exam_version_id: versions).select(:id))
                           .distinct.pluck(:lab_requisition_item_id).sort
        item_ids.each { |id| LabQcReviewItem.create!(lab_qc_block: block, lab_requisition_item_id: id) }
        item_ids.size
      end

      def since_for(block, run)
        accepted = LabQcRun.where(lab_instrument_id: block.lab_instrument_id, status: LabQcRun::ACCEPTED).where.not(id: run.id)
                           .where(id: LabQcValue.where(analyte_key: block.analyte_key).select(:lab_qc_run_id)).maximum(:started_at)
        accepted || LabQcTarget.where(lab_instrument_id: block.lab_instrument_id, analyte_key: block.analyte_key).minimum(:accepted_at) || run.started_at
      end
      private_class_method :since_for
    end
  end
end
