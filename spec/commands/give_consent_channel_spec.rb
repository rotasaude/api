require "rails_helper"

RSpec.describe GiveConsent do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:conversation) { Conversation.create!(phone: "+5541998765432", state: :awaiting_consent) }

  it "grava whatsapp quando o canal não é informado" do
    described_class.call(conversation: conversation, version: Consents.current_version, evidence: {})
    expect(conversation.consents.last.channel).to eq("whatsapp")
  end

  it "grava o canal informado" do
    described_class.call(conversation: conversation, version: Consents.current_version, evidence: {}, channel: "web")
    expect(conversation.consents.last.channel).to eq("web")
  end
end

RSpec.describe GiveConsent, "recusas" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def give(conversation, version: Consents.current_version)
    described_class.call(conversation: conversation, version: version, evidence: {})
  end

  (Conversation.states.keys - %w[awaiting_consent]).each do |state|
    it "recusa com :wrong_state quando a conversa está em #{state}, sem gravar nada" do
      conversation = Conversation.create!(phone: "+5541998760001", state: state)
      result = give(conversation)
      expect(result.reason).to eq(:wrong_state)
      expect(conversation.consents).to be_empty
      expect(conversation.reload.state).to eq(state)
    end
  end

  it "recusa com :version_mismatch quando a versão não é a vigente, sem gravar nada" do
    conversation = Conversation.create!(phone: "+5541998760002", state: :awaiting_consent)
    result = give(conversation, version: (Consents.current_version.to_i + 1).to_s)
    expect(result.reason).to eq(:version_mismatch)
    expect(conversation.consents).to be_empty
    expect(conversation.reload).to be_state_awaiting_consent
  end

  it "no reconsentimento, revoga o consentimento antigo e deixa um só ativo" do
    conversation = Conversation.create!(phone: "+5541998760003", state: :awaiting_consent)
    old = give(conversation).payload[:consent]
    conversation.update!(state: :awaiting_consent)
    fresh = give(conversation).payload[:consent]
    expect(old.reload.revoked_at).to be_present
    expect(conversation.active_consent).to eq(fresh)
  end
end

# Termo publicado no banco da cidade (city:consent_term:publish, F-06.13): o
# consentimento carrega o hash do texto QUE O CIDADÃO VIU — o body da linha —,
# não o das credentials (que para uma versão nova nem existe: daria SHA256("")).
RSpec.describe GiveConsent, "hash do texto do termo" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:conversation) { Conversation.create!(phone: "+5541998765433", state: :awaiting_consent) }

  it "usa o body do termo da cidade quando a versão está em consent_terms" do
    ConsentTerm.create!(version: "907", body: "Texto do termo 907", published_at: Time.current)

    described_class.call(conversation: conversation, version: "907", evidence: {}, channel: "web")

    expect(conversation.consents.last.policy_text_sha).to eq(Digest::SHA256.hexdigest("Texto do termo 907"))
  end

  it "sem linha no banco, cai no texto das credentials" do
    text = Rails.application.credentials.dig(:policy, "v#{Consents.current_version}", :text).to_s

    expect(Consents.policy_text_sha(Consents.current_version)).to eq(Digest::SHA256.hexdigest(text))
  end
end
