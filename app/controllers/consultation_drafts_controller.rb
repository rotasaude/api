# app/controllers/consultation_drafts_controller.rb
# Rascunho de consulta órfão (card rotasaude/api#51; ADR 0031, módulo 19a): o
# municipal_admin lista os rascunhos abertos, vê quem pode assumir e ou
# descarta (A) ou designa outro profissional da unidade (B). Atrás do
# interruptor clinical_record; papel e step-up são daqui (os comandos não
# checam papel). Listagem e candidatos não têm conteúdo clínico: sem step-up.
# Descartar e designar exigem step-up e motivo (10..500; nunca a evento/log).
class ConsultationDraftsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include MfaStepUp

  ERROR_STATUS = {
    feature_disabled: :forbidden, not_found: :not_found, not_draft: :conflict, invalid_reason: :unprocessable_entity,
    invalid_professional: :unprocessable_entity, same_author: :unprocessable_entity
  }.freeze

  wrap_parameters false
  before_action :require_clinical_record!
  before_action :require_draft_admin
  before_action :require_step_up!, only: %i[discard reassign]

  def index
    render json: { drafts: ConsultationDrafts::OpenList.call }
  end

  def candidates
    result = ConsultationDrafts::Candidates.call(consultation_id: params[:id])
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { candidates: result.payload[:candidates] }
  end

  def discard
    result = ConsultationDrafts::Discard.call(consultation_id: params[:id], reason: body["reason"], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { consultation_id: result.payload[:consultation].id, status: "discarded" }
  end

  def reassign
    result = ConsultationDrafts::Reassign.call(consultation_id: params[:id], user_id: body["user_id"],
                                               reason: body["reason"], by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    consultation = result.payload[:consultation]
    render json: { consultation_id: consultation.id,
                   author: { user_id: consultation.author_user_id, name: Screenings::Json.staff_name(consultation.author_user) } }
  end

  private

  def require_draft_admin
    forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
  end

  def body = params.to_unsafe_h.except("controller", "action", "id", "format")
end
