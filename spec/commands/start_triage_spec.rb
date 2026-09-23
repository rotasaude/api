require "rails_helper"

RSpec.describe StartTriage do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:conversation) { Conversation.create!(phone: "+5541998765432", state: :consented) }

  it "abre a triagem no primeiro passo do protocolo ativo" do
    create_default_protocol!
    result = described_class.call(conversation: conversation)
    expect(result).to be_ok
    triage = result.payload[:triage]
    expect(triage).to be_status_in_progress
    expect(triage.current_step).to eq("tosse")
    expect(triage.answers).to eq({})
  end

  it "falha com :no_protocol sem protocolo ativo" do
    expect(described_class.call(conversation: conversation).reason).to eq(:no_protocol)
  end
end
