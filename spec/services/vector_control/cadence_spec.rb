require "rails_helper"

# Módulo 35a (contrato §5; W-2, A-11): a cadência do imóvel, da linha mais
# específica para a mais geral, com o degrau (cidade, qualquer) antes do
# default_days. Pura: a tabela e os parâmetros vêm de quem chama.
RSpec.describe VectorControl::Cadence, type: :model do
  let(:place) { Data.define(:property_type) }
  let(:risk_profile) { Data.define(:risk_class) }

  let(:parameters) { VectorControl::Parameters.defaults }
  let(:nb) { SecureRandom.uuid }

  def days(table, property_type: "1", risk: nil, neighborhood_id: nb)
    described_class.days_for(profile: risk && risk_profile.new(risk_class: risk), household: place.new(property_type: property_type),
                             neighborhood_id: neighborhood_id, table: table, parameters: parameters)
  end

  it "PE: (bairro, PE) 10 → 10; sem ela (cidade, PE) 12 → 12; sem nenhuma → 15" do
    table = { [ nb, nil, true ] => 10, [ nil, nil, true ] => 12, [ nb, nil, false ] => 45, [ nil, nil, false ] => 50 }
    expect(days(table, property_type: "4")).to eq(10)
    expect(days(table.except([ nb, nil, true ]), property_type: "4")).to eq(12)
    expect(days(table.except([ nb, nil, true ], [ nil, nil, true ]), property_type: "4")).to eq(15)
    expect(days({}, property_type: "4", risk: "red")).to eq(parameters.fetch("strategic_point_days"))
  end

  it "vermelho no bairro: (bairro, red) 30 → 30; (bairro, qualquer) 45; (cidade, red) 40; (cidade, qualquer) 50; nada → 60" do
    table = { [ nb, "red", false ] => 30, [ nb, nil, false ] => 45, [ nil, "red", false ] => 40, [ nil, nil, false ] => 50,
              [ nb, nil, true ] => 10 }
    expect(days(table, risk: "red")).to eq(30)
    table.delete([ nb, "red", false ])
    expect(days(table, risk: "red")).to eq(45)
    table.delete([ nb, nil, false ])
    expect(days(table, risk: "red")).to eq(40)
    table.delete([ nil, "red", false ])
    expect(days(table, risk: "red")).to eq(50)
    table.delete([ nil, nil, false ])
    expect(days(table, risk: "red")).to eq(60)
  end

  it "sem risco ou sem bairro: só os degraus de qualquer risco e da cidade" do
    table = { [ nb, "red", false ] => 30, [ nb, nil, false ] => 45, [ nil, "red", false ] => 40, [ nil, nil, false ] => 50 }
    expect(days(table)).to eq(45)
    expect(days(table, risk: "red", neighborhood_id: nil)).to eq(40)
    expect(days(table, neighborhood_id: nil)).to eq(50)
  end

  it "default_days e strategic_point_days lidos dos parâmetros, nunca fixos" do
    tuned = parameters.merge("default_days" => 90, "strategic_point_days" => 20)
    expect(described_class.days_for(profile: nil, household: place.new(property_type: "1"), neighborhood_id: nb, table: {},
                                    parameters: tuned)).to eq(90)
    expect(described_class.days_for(profile: nil, household: place.new(property_type: "4"), neighborhood_id: nb, table: {},
                                    parameters: tuned)).to eq(20)
  end

  it ".table lê todas as linhas numa consulta, pela tripla" do
    vector_city!
    neighborhood = Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual")
    VectorCadence.create!(days: 50)
    VectorCadence.create!(neighborhood: neighborhood, risk_class: "red", days: 30)
    VectorCadence.create!(strategic_point: true, days: 12)
    expect(described_class.table).to eq([ nil, nil, false ] => 50, [ neighborhood.id, "red", false ] => 30, [ nil, nil, true ] => 12)
  end
end
