require "rails_helper"

RSpec.describe Territory::ReferenceUnits do
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }
  let!(:upa) { create_unit("UPA 24h", kind: "upa") }
  let!(:ubs) { create_unit("UBS Centro") }
  let!(:fechada) { create_unit("UBS Antiga", active: false) }

  before do
    [ upa, ubs, fechada ].each { |u| NeighborhoodCoverage.create!(neighborhood: centro, health_unit: u) }
    NeighborhoodCoverage.create!(neighborhood: batel, health_unit: fechada)
  end

  it "for: só as ativas que cobrem o bairro, por nome; nil = lista vazia" do
    expect(described_class.for(centro.id)).to eq([ ubs, upa ])
    expect(described_class.for(batel.id)).to eq([])
    expect(described_class.for(nil)).to eq([])
  end

  it "ids_by_neighborhood: várias de uma vez, mesmas regras" do
    expect(described_class.ids_by_neighborhood([ centro.id, batel.id, nil, centro.id ]))
      .to eq(centro.id => [ ubs.id, upa.id ])
    expect(described_class.ids_by_neighborhood([ nil ])).to eq({})
  end

  it "as_json_list: endereço como objeto, campos podendo ser nulos" do
    ubs.update!(address_street: "Rua XV de Novembro", address_number: "500", address_zip: "80020310")
    expect(described_class.as_json_list(described_class.for(centro.id))).to eq([
      { id: ubs.id, name: "UBS Centro", kind: "ubs",
        address: { street: "Rua XV de Novembro", number: "500", complement: nil, zip: "80020310" } },
      { id: upa.id, name: "UPA 24h", kind: "upa", address: { street: nil, number: nil, complement: nil, zip: nil } }
    ])
  end
end
