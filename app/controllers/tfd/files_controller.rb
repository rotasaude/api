# GET /tfd/files/:token (§14 T13): o comprovante da prestação de contas por
# URL curta (5 min, amarrada à cidade, ao arquivo e ao usuário), só para a
# comissão. Vencido → 410 link_expired; falso, de outro usuário ou de outro
# arquivo → 404. Cada download deixa a trilha clinical_record.viewed (access
# "tfd", só ids; FW5): o comprovante pode trazer o nome do paciente.
module Tfd
  class FilesController < BaseController
    before_action { forbid unless Access.committee?(Current.user) }

    def show
      file = Files.resolve(params[:token], user: Current.user)
      return render(json: { error: "link_expired" }, status: :gone) if file == :expired
      return not_found unless file

      row = TfdAccountability.includes(:tfd_case).find_by(exam_file_id: file.id)
      return not_found unless row

      Trail.person_viewed!(user: Current.user, patient_id: row.tfd_case.patient_id)
      response.headers["Cache-Control"] = "no-store"
      send_data file.bytes, type: file.content_type, disposition: "inline", filename: row.filename || Files.generated_name(file)
    end
  end
end
