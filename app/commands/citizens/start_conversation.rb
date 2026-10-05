# Abre ou retoma a conversa web de um cidadão, com o consentimento da versão
# vigente, e garante uma triagem em andamento. O consentimento é dado na tela
# ANTES do CPF (spec §4); aqui ele é registrado na conversa, pelo mesmo
# GiveConsent do WhatsApp, com channel "web".
# ADR 0027: o cidadão escolhe o protocolo. Uma triagem em andamento por par:
# pedir o MESMO protocolo retoma; pedir outro é :triage_in_progress. O lock é
# cidadão → conversa, a mesma ordem de Citizens::Erase (desvio 5 do plano).
# Reasons: :consent_outdated, :no_protocol, :not_offered, :triage_in_progress (e as de GiveConsent).
module Citizens
  class StartConversation
    def self.call(citizen:, consent_version:, session_id:, protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME)
      new(citizen, consent_version.to_s, session_id, protocol_name.to_s).call
    end

    def initialize(citizen, consent_version, session_id, protocol_name)
      @citizen = citizen
      @consent_version = consent_version
      @session_id = session_id
      @protocol_name = protocol_name
    end

    def call
      return Result.fail(:consent_outdated) unless @consent_version == Consents.current_version

      conversation = find_or_create_conversation
      result = nil
      # Sem lock, duas abas / toque duplo em "start" correm a mesma conversa em
      # paralelo: os dois passam pelo state_awaiting_consent? do GiveConsent
      # antes de qualquer um gravar (segundo consent duplicado ou 500 no índice
      # único), e os dois veem "nenhuma triagem em andamento" antes de qualquer
      # um criar (500 no índice único de triagem). with_lock serializa e
      # recarrega a conversa: quem chega depois já vê o estado gravado pelo
      # primeiro.
      ApplicationRecord.transaction do
        @citizen.lock!
        conversation.lock!
        result = locked_call(conversation)
      end
      result
    end

    private

    def locked_call(conversation)
      consent = ensure_consent(conversation)
      return consent if consent.failure?

      triage = conversation.triages.status_in_progress.order(created_at: :desc).first
      if triage
        return Result.fail(:triage_in_progress) unless triage.protocol_name == @protocol_name

        return Result.ok(conversation: conversation, triage: triage, resumed: true)
      end

      started = StartTriage.call(conversation: conversation, protocol_name: @protocol_name)
      return started if started.failure?

      Result.ok(conversation: conversation, triage: started.payload[:triage], resumed: false)
    end

    def active_scope
      Conversation.channel_web.where(citizen: @citizen, state: Conversation::ACTIVE_STATES)
    end

    def find_or_create_conversation
      active_scope.first ||
        Conversation.create!(channel: "web", citizen: @citizen, phone: @citizen.phone, state: :awaiting_consent)
    rescue ActiveRecord::RecordNotUnique
      active_scope.first!
    end

    # Uma conversa já consentida com termo antigo (termo novo publicado no meio
    # da triagem) volta a awaiting_consent e consente de novo; senão o
    # CompleteTriage recusaria com :no_consent.
    def ensure_consent(conversation)
      return Result.ok if conversation.consented?

      conversation.update!(state: :awaiting_consent) unless conversation.state_awaiting_consent?
      GiveConsent.call(
        conversation: conversation,
        version: @consent_version,
        channel: "web",
        evidence: { channel: "web", citizen_session_id: @session_id, version: @consent_version }
      )
    end
  end
end
