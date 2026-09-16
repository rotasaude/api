require "rails_helper"

RSpec.describe CityEncryption do
  let(:city_a) { City.new(slug: "aaa", name: "A", status: "active", encryption_key: "a" * 64) }
  let(:city_b) { City.new(slug: "bbb", name: "B", status: "active", encryption_key: "b" * 64) }

  it "gives each city different key material" do
    expect(described_class.key_provider(city_a).encryption_key.secret)
      .not_to eq(described_class.key_provider(city_b).encryption_key.secret)
    expect(described_class.deterministic_key_provider(city_a).encryption_key.secret)
      .not_to eq(described_class.deterministic_key_provider(city_b).encryption_key.secret)
  end

  it "is stable for the same city" do
    expect(described_class.key_provider(city_a).encryption_key.secret)
      .to eq(described_class.key_provider(city_a).encryption_key.secret)
  end

  # Context::PROPERTIES não tem deterministic_key_provider — passar isso levanta
  # NoMethodError. O contexto só carrega o provedor não-determinístico.
  it "context_properties carries only key_provider" do
    expect(described_class.context_properties(city_a).keys).to eq([ :key_provider ])
  end

  it "fails closed without key material" do
    expect { described_class.key_provider(City.new(slug: "x", name: "X")) }.to raise_error(CityEncryption::MissingKey)
    expect { described_class.deterministic_key_provider(nil) }.to raise_error(CityEncryption::MissingKey)
  end
end
