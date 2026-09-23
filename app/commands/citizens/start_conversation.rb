# Abre ou retoma a conversa web de um cidadão, com o consentimento da versão
# vigente, e garante uma triagem em andamento. O consentimento é dado na tela
# ANTES do CPF (spec §4); aqui ele é registrado na conversa, pelo mesmo
# GiveConsent do WhatsApp, com channel "web".
# Reasons: :consent_outdated, :no_protocol (e as de GiveConsent).
module Citizens
  class StartConversation
    def self.call(citizen:, consent_version:, session_id:)
      new(citizen, consent_version.to_s, session_id).call
    end

    def initialize(citizen, consent_version, session_id)
      @citizen = citizen
      @consent_version = consent_version
      @session_id = session_id
    end

    def call
      return Result.fail(:consent_outdated) unless @consent_version == Consents.current_version

      conversation = find_or_create_conversation
      consent = ensure_consent(conversation)
      return consent if consent.failure?

      triage = conversation.triages.status_in_progress.order(created_at: :desc).first
      return Result.ok(conversation: conversation, triage: triage, resumed: true) if triage

      started = StartTriage.call(conversation: conversation)
      return started if started.failure?

      Result.ok(conversation: conversation, triage: started.payload[:triage], resumed: false)
    end

    private

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
