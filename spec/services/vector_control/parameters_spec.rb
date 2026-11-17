require "rails_helper"

# Módulo 35a (contrato §11; A-4): a vigente é a maior versão gravada; sem
# linha, versão 0 com o padrão de fábrica do defaults.yml.
RSpec.describe VectorControl::Parameters, type: :model do
  before { vector_city! }

  let(:factory) { YAML.load_file(Rails.root.join("config/vector_control/defaults.yml")) }

  it "sem versão → version 0 e o defaults.yml" do
    expect(VectorParameterVersion.count).to eq(0)
    expect(described_class.current).to eq(described_class::Snapshot.new(version: 0, values: factory))
    expect(described_class.defaults).to eq(factory)
  end

  it "a maior versão vale" do
    coordinator = endemic_coordinator!
    VectorParameterVersion.create!(version: 2, values: factory.merge("default_days" => 45), created_by_user: coordinator)
    VectorParameterVersion.create!(version: 1, values: factory, created_by_user: coordinator)
    current = described_class.current
    expect(current.version).to eq(2)
    expect(current.values).to eq(factory.merge("default_days" => 45))
  end

  it "RANGES (A-5, Q17) cobre as 20 chaves do defaults.yml, na mesma ordem" do
    expect(described_class::RANGES.keys).to eq(factory.keys)
    expect(factory.size).to eq(20)
  end

  it "validate: o padrão de fábrica passa (com a lista de doenças); sem ela, block_diseases não passa" do
    expect(described_class.validate(factory)).to eq(path: "block_diseases")
    surveillance_city!
    expect(described_class.validate(factory)).to be_nil
    expect(described_class.validate(factory.merge("liraa_half_household_fraction" => 1.01))).to eq(path: "liraa_half_household_fraction")
  end

  it "version 0 tem created_at nil; a gravada, o da linha" do
    expect(described_class.current.created_at).to be_nil
    row = VectorParameterVersion.create!(version: 1, values: factory, created_by_user: endemic_coordinator!)
    expect(described_class.current.created_at).to eq(row.created_at)
  end
end
