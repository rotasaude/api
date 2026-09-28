require "rails_helper"

RSpec.describe StartTriage, "cópia do bairro (ADR 0023)" do
  before { create_default_protocol! }

  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }

  def web_conversation(citizen)
    Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "consented")
  end

  it "a triagem nasce com o bairro atual do cidadão; trocar depois não muda a triagem" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: centro)
    triage = described_class.call(conversation: web_conversation(citizen)).payload[:triage]
    expect(triage.neighborhood_id).to eq(centro.id)

    Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: batel.id)
    expect(triage.reload.neighborhood_id).to eq(centro.id)
  end

  it "cidadão sem bairro, ou conversa do WhatsApp sem cidadão: triagem sem bairro" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    expect(described_class.call(conversation: web_conversation(citizen)).payload[:triage].neighborhood_id).to be_nil

    whatsapp = Conversation.create!(phone: "+5541911112222", state: "consented")
    expect(described_class.call(conversation: whatsapp).payload[:triage].neighborhood_id).to be_nil
  end
end
