# GET /tfd/files/:token (§14 T13): o comprovante da prestação de contas por
# URL curta (5 min, amarrada à cidade, ao arquivo e ao usuário), só para a
# comissão. Vencido → 410 link_expired; falso, de outro usuário ou de outro
# arquivo → 404. Sem trilha (o comprovante não é dado clínico).
module Tfd
  class FilesController < BaseController
    before_action { forbid unless Access.committee?(Current.user) }

    def show
      file = Files.resolve(params[:token], user: Current.user)
      return render(json: { error: "link_expired" }, status: :gone) if file == :expired
      return not_found unless file

      response.headers["Cache-Control"] = "no-store"
      send_data file.bytes, type: file.content_type, disposition: "inline",
                            filename: TfdAccountability.find_by(exam_file_id: file.id)&.filename || Files.generated_name(file)
    end
  end
end
