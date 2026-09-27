require "rails_helper"

# F-02.5 (ADR 0008): revogar marca o consentimento, encerra a conversa em
# revoked, aborta a triagem em andamento e publica consent.revoked — tudo ou
# nada.
RSpec.describe RevokeConsent do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:conversation) { Conversation.create!(phone: "+5541998761001", state: :awaiting_consent) }

  def consent!
    GiveConsent.call(conversation: conversation, version: Consents.current_version, evidence: {}).payload[:consent]
  end

  it "recusa com :no_active_consent sem consentimento, sem mudar nada nem publicar" do
    conversation.update!(state: :consented)
    expect(DomainEvents).not_to receive(:publish)
    result = described_class.call(conversation: conversation)
    expect(result.reason).to eq(:no_active_consent)
    expect(conversation.reload).to be_state_consented
  end

  it "revoga sem triagem em andamento: consentimento marcado, conversa revoked, evento publicado" do
    consent = consent!
    allow(DomainEvents).to receive(:publish)
    result = described_class.call(conversation: conversation, reason: "revogar")

    expect(result).to be_ok
    expect(consent.reload.revoked_at).to be_present
    expect(conversation.reload).to be_state_revoked
    expect(DomainEvents).to have_received(:publish)
      .with("consent.revoked", conversation_id: conversation.id, consent_id: consent.id, reason: "revogar")
  end

  it "é tudo ou nada: se publicar falha, nada fica revogado" do
    consent = consent!
    allow(DomainEvents).to receive(:publish).and_raise("falha ao publicar")
    expect { described_class.call(conversation: conversation) }.to raise_error("falha ao publicar")
    expect(consent.reload.revoked_at).to be_nil
    expect(conversation.reload).to be_state_consented
  end
end
