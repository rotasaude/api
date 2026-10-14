# GET /exams/files/:token (Divergência D4): a URL curta do laudo ou da guia.
# Quem gerou a URL já passou pela regra de leitura. Contrato A27: o download do
# PDF de um RESULTADO deixa a trilha clinical_record.viewed (access exam_result);
# a guia (recepção) não deixa.
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

    # Ponto único da A27: a trilha do laudo.
    def record_result_view(file)
      result = ExamResult.find_by(pdf_file_id: file.id)
      return unless result

      grant = ClinicalRecord::Access::Grant.new(kind: :exam_result, opening: nil, reason: nil)
      ClinicalRecord::Trail.viewed!(patient: result.patient, user: Current.user, grant: grant,
                                    extra: { exam_result_id: result.id, exam_order_id: result.exam_order_id })
    end
  end
end
