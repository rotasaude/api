require "rails_helper"

RSpec.describe Citizens::SetNeighborhood do
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }

  def payloads = DomainEvent.where(name: "citizen.neighborhood_changed").map(&:payload)

  it "grava, troca e apaga, com um evento por mudança, só ids" do
    described_class.call(citizen: citizen, neighborhood_id: centro.id)
    described_class.call(citizen: citizen, neighborhood_id: batel.id.upcase)
    described_class.call(citizen: citizen, neighborhood_id: nil)

    expect(citizen.reload.neighborhood_id).to be_nil
    expect(payloads).to eq([
      { "citizen_id" => citizen.id, "from_id" => nil, "to_id" => centro.id },
      { "citizen_id" => citizen.id, "from_id" => centro.id, "to_id" => batel.id },
      { "citizen_id" => citizen.id, "from_id" => batel.id, "to_id" => nil }
    ])
  end

  it "mesmo bairro, ou nil sem bairro: ok, sem evento" do
    described_class.call(citizen: citizen, neighborhood_id: "")
    described_class.call(citizen: citizen, neighborhood_id: centro.id)
    described_class.call(citizen: citizen, neighborhood_id: centro.id)
    expect(payloads.size).to eq(1)
  end

  it "bairro inativo, inexistente ou id que não é UUID: invalid_neighborhood e nada muda" do
    centro.update!(active: false)
    [ centro.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
      expect(described_class.call(citizen: citizen, neighborhood_id: id).reason).to eq(:invalid_neighborhood)
    end
    expect(citizen.reload.neighborhood_id).to be_nil
    expect(payloads).to be_empty
  end
end
