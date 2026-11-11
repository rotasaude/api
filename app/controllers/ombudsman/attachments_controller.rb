# Anexos da ouvidoria para a equipe (ADR 0051; contrato §5; Q2, Q43, U4).
#   POST /ombudsman/attachments { filename, content_type, data } → 201 { id }:
#     técnico ou ouvidor; dono = o usuário; 20 por hora por usuário.
#   POST /ombudsman/attachments/:id/link { justification? } → { url, expires_at }:
#     URL curta (5 min) do download. Manifestação identificada: técnico ou
#     ouvidor. Preservada ou anônima: só o ouvidor (403 missing_role), com a
#     justificativa (10–500; senão 422 path "justification"), que grava o acesso
#     (scope "attachment") e ombudsman.identity_viewed (só manifestation_id).
#     Sem step-up (U4). Anexo órfão ou inexistente → 404.
module Ombudsman
  class AttachmentsController < BaseController
    rate_limit to: 20, within: 1.hour, only: :create, name: "ombudsman_attachment",
               by: -> { Current.user.id }, store: RateLimitStore,
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }
    before_action :require_staff!

    def create
      return unless query_only!

      result = Attachments.upload(data: body_param("data"), content_type: body_param("content_type"), filename: body_param("filename"),
                                  user: Current.user)
      return render_failure(result) if result.failure?

      render json: { id: result.payload.fetch(:attachment).id }, status: :created
    end

    def link
      return unless query_only!

      attachment = uuid?(params[:id]) ? OmbudsmanAttachment.find_by(id: params[:id]) : nil
      manifestation = attachment&.ombudsman_manifestation
      return not_found unless manifestation

      justification = nil
      unless manifestation.identification_mode == "identified"
        return unless require_ombudsman_role!

        justification = Input.text(body_param("justification"), Catalog::JUSTIFICATION)
        return render_refusal("justification") unless justification

        record_access!(manifestation, attachment, justification)
      end

      render json: Files.link_for(attachment.exam_file_id, user: Current.user)
    end

    private

    def record_access!(manifestation, attachment, justification)
      ApplicationRecord.transaction do
        OmbudsmanIdentityAccess.create!(ombudsman_manifestation: manifestation, user: Current.user, scope: "attachment",
                                        exam_file_id: attachment.exam_file_id, justification: justification)
        DomainEvents.publish("ombudsman.identity_viewed", manifestation_id: manifestation.id)
      end
    end
  end
end
