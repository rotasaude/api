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
    result = described_class.call(conversation: conversation, origin: "web")
    expect(result.reason).to eq(:no_active_consent)
    expect(conversation.reload).to be_state_consented
  end

  it "revoga sem triagem em andamento: consentimento marcado, conversa revoked, evento publicado" do
    consent = consent!
    allow(DomainEvents).to receive(:publish)
    result = described_class.call(conversation: conversation, origin: "web")

    expect(result).to be_ok
    expect(consent.reload.revoked_at).to be_present
    expect(conversation.reload).to be_state_revoked
    expect(DomainEvents).to have_received(:publish)
      .with("consent.revoked", conversation_id: conversation.id, consent_id: consent.id, origin: "web")
  end

  it "é tudo ou nada: se publicar falha, nada fica revogado" do
    consent = consent!
    allow(DomainEvents).to receive(:publish).and_raise("falha ao publicar")
    expect { described_class.call(conversation: conversation, origin: "web") }.to raise_error("falha ao publicar")
    expect(consent.reload.revoked_at).to be_nil
    expect(conversation.reload).to be_state_consented
  end

  it "grava a origem da revogação, nunca o texto do cidadão" do
    consent!
    described_class.call(conversation: conversation, origin: "whatsapp")
    event = DomainEvent.where(name: "consent.revoked").order(:created_at).last
    expect(event.payload).to include("origin" => "whatsapp")
    expect(event.payload).not_to have_key("reason")
  end

  it "recusa origem desconhecida" do
    expect { described_class.call(conversation: conversation, origin: "apagar meus dados") }
      .to raise_error(ArgumentError, /origin/)
  end
end
