# POST /exams/uploads (Divergência D3): JSON { content_type, data(base64) } → { upload_id }.
# Quem sobe: a unidade (recepção ou profissional com vínculo) ou o prestador.
module Exams
  class UploadsController < BaseController
    def create
      provider = ExamProviderUser.find_by(user_id: Current.user.id)&.exam_provider if Current.user.has_role?("exam_provider")
      allowed = provider || Current.user.has_role?("citizen_verifier") || Current.user.has_role?("health_professional")
      return forbid("missing_role") unless allowed

      result = Exams::Files.store_base64(data: params[:data], content_type: params[:content_type], user: Current.user)
      return render_failure(result) if result.failure?

      render json: { upload_id: result.payload[:file].id }, status: :created
    end
  end
end
