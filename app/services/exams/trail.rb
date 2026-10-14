# Trilha da leitura clínica do exame (ADR 0036; contrato §12 e A27): o mesmo
# clinical_record.viewed do 19a (ClinicalRecord::Trail), só ids. A forma
# administrativa não deixa trilha (não tem conteúdo clínico).
module Exams
  module Trail
    RESULT_GRANT = ClinicalRecord::Access::Grant.new(kind: :exam_result, opening: nil, reason: nil)

    module_function

    def viewed!(order:, user:, grant:)
      return unless grant&.view == :clinical

      ClinicalRecord::Trail.viewed!(patient: order.patient, user: user,
                                    grant: ClinicalRecord::Access::Grant.new(kind: grant.kind, opening: grant.opening, reason: nil),
                                    extra: { exam_order_id: order.id })
    end

    # O download do laudo (Exams::FilesController, A27).
    def result_viewed!(result:, user:)
      ClinicalRecord::Trail.viewed!(patient: result.patient, user: user, grant: RESULT_GRANT,
                                    extra: { exam_result_id: result.id, exam_order_id: result.exam_order_id })
    end
  end
end
