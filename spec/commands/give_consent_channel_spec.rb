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
