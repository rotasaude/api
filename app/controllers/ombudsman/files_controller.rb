# GET /ombudsman/files/:token (ADR 0051; contrato §5; Q14): o anexo por URL
# curta (5 min, amarrada à cidade, ao arquivo e ao usuário), só para a
# equipe. Vencido → 410 link_expired; falso, de outro usuário, de arquivo que
# não é da ouvidoria ou ainda órfão → 404. O nome devolvido é o gerado
# ("anexo-<id>.<ext>"), nunca o gravado.
module Ombudsman
  class FilesController < BaseController
    before_action :require_staff!

    def show
      return unless query_only!

      file = Files.resolve(params[:token], user: Current.user)
      return render(json: { error: "link_expired" }, status: :gone) if file == :expired

      attachment = file && OmbudsmanAttachment.where.not(ombudsman_manifestation_id: nil).find_by(exam_file_id: file.id)
      return not_found unless attachment

      response.headers["Cache-Control"] = "no-store"
      send_data file.bytes, type: file.content_type, disposition: "inline", filename: Files.filename(attachment, file)
    end
  end
end
