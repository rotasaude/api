#   GET  /citizen/triages?citizen_id=
#   GET  /citizen/triages/:id
#   POST /citizen/triages/:id/revoke_consent
# O nível declarado vê só as triagens do próprio par CPF + telefone (spec §2.3).
module CitizenApi
  class TriagesController < BaseController
    def index
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen

      triages = scoped_triages.where(conversations: { citizen_id: citizen.id }).order(created_at: :desc)
      render json: {
        citizen: { id: citizen.id, cpf_masked: citizen.cpf_masked, verification_level: citizen.verification_level },
        triages: triages.map { |t| summary(t) }
      }
    end

    def show
      triage = scoped_triages.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless triage

      render json: summary(triage)
    end

    def revoke_consent
      triage = scoped_triages.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless triage

      result = RevokeConsent.call(conversation: triage.conversation, reason: "citizen_web")
      return render_error(result.reason, :conflict) if result.failure?

      render json: summary(triage.reload)
    end

    private

    def scoped_triages
      Triage.joins(:conversation).where(
        conversations: { channel: "web", citizen_id: current_citizen_session.citizens.select(:id) }
      )
    end

    def summary(triage)
      {
        id: triage.id,
        status: triage.status,
        tier: triage.tier,
        priority: triage.priority,
        created_at: triage.created_at.iso8601,
        completed_at: triage.completed_at&.iso8601,
        report_url: triage.report_snapshot&.url,
        consent_active: triage.conversation.active_consent.present?
      }
    end
  end
end
