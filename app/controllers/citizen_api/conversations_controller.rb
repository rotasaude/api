#   POST /citizen/conversations              { citizen_id | cpf, consent_version, protocol_name, neighborhood_id? }
#   POST /citizen/conversations/:id/answers  { answer, idempotency_key }
#   POST /citizen/conversations/:id/undo
module CitizenApi
  class ConversationsController < BaseController
    START_ERRORS = {
      consent_outdated: :conflict, wrong_state: :conflict, version_mismatch: :conflict,
      not_offered: :conflict, triage_in_progress: :conflict, no_protocol: :service_unavailable
    }.freeze

    def create
      # LGPD (spec §4): nenhum CPF é gravado sem o consentimento da versão
      # vigente. Confira ANTES de resolve_citizen, que só acha o par — o par
      # novo nasce pelo POST /citizen/people.
      unless params[:consent_version].to_s == Consents.current_version
        return render_error("consent_outdated", :conflict)
      end

      # ADR 0027: o cidadão escolhe o protocolo no catálogo. Antes de
      # resolve_citizen, como o consentimento: um pedido recusado não grava CPF.
      protocol_name = params[:protocol_name]
      unless protocol_name.is_a?(String) && protocol_name.present?
        return render_error("protocol_name_required", :unprocessable_entity)
      end

      # ADR 0023: bairro inválido é recusado ANTES de resolve_citizen — um
      # pedido recusado não grava nada. Depois do consentimento.
      neighborhood_id = requested_neighborhood_id
      return if performed?

      citizen = resolve_citizen
      return if performed?

      # O catálogo é por perfil (ADR 0027): sem perfil, o wpda pede antes.
      return render_error("profile_required", :conflict) unless citizen.profile?

      # Grava só quando a pessoa ainda não tem bairro; a troca é pela rota
      # própria. Antes do StartConversation: a triagem nova copia o bairro.
      if neighborhood_id && citizen.neighborhood_id.nil?
        set = Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: neighborhood_id)
        return render_error(set.reason, :unprocessable_entity) if set.failure?
      end

      result = Citizens::StartConversation.call(
        citizen: citizen, consent_version: params[:consent_version], session_id: current_citizen_session.id,
        protocol_name: protocol_name
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
        # Caminho de compatibilidade: só ACHA o par. O par novo nasce pelo POST
        # /citizen/people, com o perfil (ADR 0027) — aqui um CPF novo seria
        # recusado com profile_required, e um pedido recusado não grava CPF.
        digits = CitizenIdentity::Cpf.normalize(params[:cpf])
        return render_error("invalid_cpf", :unprocessable_entity) unless digits

        citizen = current_citizen_session.citizens.find_by(cpf: digits)
        render_error("profile_required", :conflict) unless citizen
        citizen
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
