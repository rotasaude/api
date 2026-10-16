# GET /exams/files/:token (Divergência D4): a URL curta do laudo ou da guia.
# Quem gerou a URL já passou pela regra de leitura. Contrato A27: o download do
# PDF de um RESULTADO deixa a trilha clinical_record.viewed (access exam_result);
# o do laudo do laboratório, access lab_report (ADR 0037); a guia (recepção) não deixa.
module Exams
  class FilesController < BaseController
    def show
      file = Exams::Files.resolve(params[:token], user: Current.user)
      return render(json: { error: "link_expired" }, status: :gone) if file == :expired
      return not_found unless file&.consumed?

      record_result_view(file)
      response.headers["Cache-Control"] = "no-store"
      send_data file.bytes, type: file.content_type, disposition: "inline", filename: Exams::Files.filename(file)
    end

    private

    # Ponto único da A27: a trilha do laudo. ADR 0037: o PDF do laudo do
    # laboratório (lab_reports.pdf_file_id; cada resultado do 21a tem cópia própria).
    def record_result_view(file)
      result = ExamResult.find_by(pdf_file_id: file.id)
      return Exams::Trail.result_viewed!(result: result, user: Current.user) if result

      report = LabReport.find_by(pdf_file_id: file.id)
      return unless report

      ClinicalRecord::Trail.viewed!(patient: report.lab_requisition.patient, user: Current.user, grant: Lab::ReleasesController::GRANT,
                                    extra: { lab_report_id: report.id, lab_requisition_id: report.lab_requisition_id })
    end
  end
end
