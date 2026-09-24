require "rails_helper"

RSpec.describe HealthUnit do
  it "nome único sem distinguir maiúsculas" do
    described_class.create!(name: "UBS Centro", kind: "ubs")
    dup = described_class.new(name: "ubs centro", kind: "upa")
    expect(dup).not_to be_valid
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "tipo precisa ser conhecido" do
    expect(described_class.new(name: "X", kind: "clinica")).not_to be_valid
  end

  it "nome é despido de espaço antes de validar/salvar: colide com a mesma unidade sem espaço" do
    described_class.create!(name: "UBS Centro", kind: "ubs")
    dup = described_class.new(name: "UBS Centro ", kind: "ubs")
    expect(dup).not_to be_valid
    expect(dup.errors.details[:name]).to include(a_hash_including(error: :taken))
  end

  it "nome é despido de espaço nas pontas ao salvar" do
    unit = described_class.create!(name: "  UBS Norte  ", kind: "ubs")
    expect(unit.name).to eq("UBS Norte")
  end

  it "lista só as ativas" do
    a = described_class.create!(name: "A", kind: "ubs")
    described_class.create!(name: "B", kind: "upa", active: false)
    expect(described_class.active_units).to eq([a])
  end
end
