# app/services/clinical_documents/content/exam_requisition.rb
# Requisição de exames (spec §4): a renderização dos pedidos estruturados da
# consulta (consultation_exam_requests, os vigentes depois dos adendos), com a
# competência SIGTAP gravada no ato. O módulo 21 consome a entidade, não o PDF.
module ClinicalDocuments
  module Content
    module ExamRequisition
      module_function

      def call(input, consultation:)
        input = Input.object(input)
        exams = Consultations::Effective.call(consultation)[:exam_requests]
        return Result.fail(:no_exam_requests) if exams.empty?

        note = Input.text(input["note"], 1..500)
        return Input.invalid("note") if note == :invalid

        rows = exams.map do |exam|
          label = ClinicalTerms::SigtapExams.label(exam.sigtap_code, exam.sigtap_competence)
          # Sem rótulo o canônico seria inválido (label é obrigatório): recusa aqui.
          return Input.invalid("exams") if label.blank?

          { "sigtap_code" => exam.sigtap_code, "label" => label,
            "competence" => exam.sigtap_competence, "cid10_justification" => exam.cid10_justification }.compact
        end
        Result.ok(content: { "exams" => rows, "note" => note })
      end
    end
  end
end
