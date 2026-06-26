# Concede consentimento à conversa. Ver ADR-0006 e ADR-0012.
# Reasons: :wrong_state, :version_mismatch.
class GiveConsent
  def self.call(conversation:, version:, evidence:)
    new(conversation: conversation, version: version, evidence: evidence).call
  end

  def initialize(conversation:, version:, evidence:)
    @conversation = conversation
    @version = version
    @evidence = evidence
  end

  def call
    return Result.fail(:wrong_state)      unless @conversation.state_awaiting_consent?
    return Result.fail(:version_mismatch) unless @version == Consents.current_version(@conversation.municipality_id)

    consent = nil
    ApplicationRecord.transaction do
      @conversation.active_consent&.revoke!
      consent = @conversation.consents.create!(
        version: @version,
        policy_text_sha: Consents.policy_text_sha(@version),
        given_at: Time.current,
        channel: "whatsapp",
        evidence: @evidence
      )
      @conversation.update!(state: :consented)

      DomainEvents.publish("consent.given", conversation_id: @conversation.id, consent_id: consent.id, version: @version)
    end

    Result.ok(consent: consent)
  end
end
