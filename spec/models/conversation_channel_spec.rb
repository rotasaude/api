require "rails_helper"

RSpec.describe Conversation do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "nasce no canal whatsapp" do
    expect(described_class.create!(phone: "+5541998765432", state: :greeting)).to be_channel_whatsapp
  end

  it "o mesmo telefone tem uma conversa ativa no WhatsApp e outra na web sem colidir" do
    described_class.create!(phone: citizen.phone, state: :consented)
    expect {
      described_class.create!(phone: citizen.phone, state: :consented, channel: "web", citizen: citizen)
    }.not_to raise_error
  end

  it "Conversation.for (WhatsApp) ignora a conversa da web do mesmo telefone" do
    web = described_class.create!(phone: citizen.phone, state: :consented, channel: "web", citizen: citizen)
    whatsapp = described_class.for(citizen.phone)
    expect(whatsapp).not_to eq(web)
    expect(whatsapp).to be_channel_whatsapp
  end

  it "um cidadão tem no máximo uma conversa ativa na web" do
    described_class.create!(phone: citizen.phone, state: :consented, channel: "web", citizen: citizen)
    expect {
      described_class.create!(phone: citizen.phone, state: :awaiting_consent, channel: "web", citizen: citizen)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
