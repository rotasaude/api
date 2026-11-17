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
end
