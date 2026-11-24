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
    @defaults_dir = Dir.mktmpdir("zoonoses-defaults")
    path = Pathname.new(@defaults_dir).join("defaults.yml")
    File.write(path, factory.to_yaml)
    stub_const("Zoonoses::Parameters::DEFAULTS_PATH", path)
  end

  after { FileUtils.remove_entry(@defaults_dir) if @defaults_dir }

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

# O PUT (Task 16): faixas e a tabela da amostra, com o defaults.yml de verdade.
RSpec.describe Zoonoses::Parameters, ".validate", type: :model do
  let(:factory) { described_class.defaults }

  it "RANGES tem as mesmas chaves do defaults.yml, sem leish_expected_prevalence (Q18)" do
    expect(described_class::RANGES.keys).to eq(factory.keys)
    expect(factory).not_to have_key("leish_expected_prevalence")
  end

  it "o padrão de fábrica passa, inclusive a tabela com min_population e a_conferir" do
    expect(described_class.validate(factory)).to be_nil
    expect(described_class.normalize(factory)).to eq(factory)
  end

  it "min_population só na primeira linha; população estritamente crescente; amostra <= população" do
    row = { "population" => 100, "sample" => 50 }
    expect(described_class.validate(factory.merge("leish_sample_table" => [ row.merge("min_population" => 80), { "population" => 200, "sample" => 90 } ]))).to be_nil
    expect(described_class.validate(factory.merge("leish_sample_table" => [ row, row.merge("min_population" => 80, "population" => 200) ])))
      .to eq(path: "leish_sample_table")
    expect(described_class.validate(factory.merge("leish_sample_table" => [ row, row ]))).to eq(path: "leish_sample_table")
  end

  it "não é objeto → path nil; tipo errado → a chave" do
    expect(described_class.validate([])).to eq(path: nil)
    expect(described_class.validate(factory.merge("collar_months" => 6.0))).to eq(path: "collar_months")
  end
end
