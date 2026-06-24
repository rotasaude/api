# Revoga consentimento e aborta triage em curso. Ver ADR-0006 e ADR-0012.
# Reasons: :no_active_consent.
class RevokeConsent
  def self.call(conversation:, reason: nil)
    new(conversation: conversation, reason: reason).call
  end

  def initialize(conversation:, reason:)
    @conversation = conversation
    @reason = reason
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

      DomainEvents.publish("consent.revoked", conversation_id: @conversation.id, consent_id: active.id, reason: @reason)
    end

    Result.ok(conversation: @conversation)
  end
end
