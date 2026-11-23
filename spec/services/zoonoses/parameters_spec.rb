require "rails_helper"

# Módulo 35b (contrato §9; molde do VectorControl::Parameters): a vigente é a
# maior versão gravada; sem linha, versão 0 com o padrão de fábrica do
# defaults.yml. Os valores do arquivo são da Task 1 (prova técnica); aqui o
# arquivo é um de teste, para provar só o mecanismo.
RSpec.describe Zoonoses::Parameters, type: :model do
  # Antes do stub: o arquivo de verdade (Task 1).
  real_path = Zoonoses::Parameters::DEFAULTS_PATH

  it "lê config/zoonoses/defaults.yml" do
    expect(real_path).to eq(Rails.root.join("config/zoonoses/defaults.yml"))
  end

  before do
    zoonoses_city!
    path = Pathname.new(Dir.mktmpdir("zoonoses-defaults")).join("defaults.yml")
    File.write(path, factory.to_yaml)
    stub_const("Zoonoses::Parameters::DEFAULTS_PATH", path)
  end

  let(:factory) { { "observation_days" => 10, "collar_months" => 6, "dog_population_estimate" => nil } }

  it "sem versão → versão 0 e defaults.yml" do
    expect(ZoonosesParameterVersion.count).to eq(0)
    expect(described_class.current).to eq(described_class::Snapshot.new(version: 0, values: factory))
    expect(described_class.current.created_at).to be_nil
    expect(described_class.defaults).to eq(factory)
    expect(described_class.at(0)).to eq(described_class::Snapshot.new(version: 0, values: factory))
    expect(described_class.at(nil).version).to eq(0)
    expect(described_class.at(7).version).to eq(0)
  end

  it "a maior vale" do
    coordinator = zoonoses_coordinator!
    ZoonosesParameterVersion.create!(version: 2, values: factory.merge("observation_days" => 15), created_by_user: coordinator)
    first = ZoonosesParameterVersion.create!(version: 1, values: factory.except("collar_months"), created_by_user: coordinator)
    current = described_class.current
    expect(current.version).to eq(2)
    expect(current.values).to eq(factory.merge("observation_days" => 15))
    # A gravada antes de uma chave existir é completada pelo padrão de fábrica.
    expect(described_class.at(1)).to eq(described_class::Snapshot.new(version: 1, values: factory, created_at: first.created_at))
  end
end
