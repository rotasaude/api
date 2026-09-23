#   POST /citizen/conversations              { citizen_id | cpf, consent_version }
#   POST /citizen/conversations/:id/answers  { answer, idempotency_key }
#   POST /citizen/conversations/:id/undo
module CitizenApi
  class ConversationsController < BaseController
    START_ERRORS = {
      consent_outdated: :conflict, wrong_state: :conflict, version_mismatch: :conflict,
      no_protocol: :service_unavailable
    }.freeze

    def create
      citizen = resolve_citizen
      return if performed?

      result = Citizens::StartConversation.call(
        citizen: citizen, consent_version: params[:consent_version], session_id: current_citizen_session.id
      )
      return render_error(result.reason, START_ERRORS.fetch(result.reason, :unprocessable_entity)) if result.failure?

      payload = result.payload
      render json: {
        conversation_id: payload[:conversation].id,
        citizen_id: citizen.id,
        resumed: payload[:resumed],
        step: Citizens::StepPayload.for(payload[:triage])
      }, status: payload[:resumed] ? :ok : :created
    end

    def answer
      conversation = find_conversation
      return if performed?
      return render_error("idempotency_key_required", :unprocessable_entity) if params[:idempotency_key].blank?

      result = Citizens::SubmitAnswer.call(
        conversation: conversation, answer: params[:answer], idempotency_key: params[:idempotency_key]
      )
      if result.failure?
        status = result.reason == :invalid_answer ? :unprocessable_entity : :conflict
        return render_error(result.reason, status)
      end

      render json: triage_state(result.payload[:triage])
    end

    def undo
      conversation = find_conversation
      return if performed?

      triage = conversation.triages.order(created_at: :desc).first
      return render_error("not_in_progress", :conflict) unless triage

      result = UndoLastAnswer.call(triage: triage)
      return render_error(result.reason, :conflict) if result.failure?

      render json: triage_state(triage.reload)
    end

    private

    def resolve_citizen
      if params[:citizen_id].present?
        citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
        render_error("not_found", :not_found) unless citizen
        citizen
      else
        result = Citizens::RegisterPerson.call(phone: current_citizen_session.phone, cpf: params[:cpf])
        render_error(result.reason, :unprocessable_entity) if result.failure?
        result.payload[:citizen]
      end
    end

    def find_conversation
      conversation = Conversation.channel_web
                                 .where(citizen_id: current_citizen_session.citizens.select(:id))
                                 .find_by(id: params[:id])
      render_error("not_found", :not_found) unless conversation
      conversation
    end

    def triage_state(triage)
      if triage.status_in_progress?
        { status: "in_progress", step: Citizens::StepPayload.for(triage) }
      else
        { status: triage.status, triage_id: triage.id }
      end
    end
  end
end
