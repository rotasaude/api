# Laudos do laboratório (contrato §5). Cresce na Task 19 (retificação).
module Lab
  class ReportsController < BaseController
    before_action :load_report

    # URL curta do PDF (A4 do 21a): a trilha é gravada no download
    # (Exams::FilesController, access lab_report), não aqui.
    def pdf
      return not_found unless @report.pdf_file

      render json: { pdf_url: Exams::Files.url_for(@report.pdf_file, user: Current.user) }
    end

    private

    def load_report
      @report = uuid?(params[:id]) && LabReport.find_by(id: params[:id])
      return not_found unless @report

      forbid unless Lab::Access.member?(Current.user, @report.exam_provider_id)
    end
  end
end
