# Revoga consentimento e aborta triage em curso. Ver ADR-0004 e ADR-0008.
# Reasons: :no_active_consent.
class RevokeConsent
  # ADR 0026: o evento (imutável) leva só a origem da revogação, nunca o texto do cidadão.
  ORIGINS = %w[web whatsapp erasure].freeze

  def self.call(conversation:, origin:)
    raise ArgumentError, "origin must be one of #{ORIGINS.join(', ')}" unless ORIGINS.include?(origin)

    new(conversation: conversation, origin: origin).call
  end

  def initialize(conversation:, origin:)
    @conversation = conversation
    @origin = origin
  end

  def call
    active = @conversation.active_consent
    return Result.fail(:no_active_consent) if active.nil?

    ApplicationRecord.transaction do
      active.revoke!
      @conversation.update!(state: :revoked)
      @conversation.triages.where(status: :in_progress).order(created_at: :desc).first&.update!(
        status: :aborted_by_revocation,
        completed_at: Time.current
      )
      # ADR 0027 (spec 2026-10-05 §5.5): somem as sugestões nascidas das
      # triagens desta conversa; o perfil, como o bairro, é cadastro e fica.
      TriageSuggestion.where(source_triage_id: @conversation.triages.select(:id)).delete_all

      DomainEvents.publish("consent.revoked", conversation_id: @conversation.id, consent_id: active.id, origin: @origin)
    end

    Result.ok(conversation: @conversation)
  end
end
