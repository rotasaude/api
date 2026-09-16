require "rails_helper"

RSpec.describe CityEncryption do
  let(:city_a) { City.new(slug: "aaa", name: "A", status: "active", encryption_key: "a" * 64) }
  let(:city_b) { City.new(slug: "bbb", name: "B", status: "active", encryption_key: "b" * 64) }

  # A Global Constraint proíbe imprimir material de chave; comparar digests faz
  # com que um diff de falha do RSpec mostre hashes, nunca o segredo derivado.
  def digest_of(key) = Digest::SHA256.hexdigest(key.secret)

  it "gives each city different key material" do
    expect(digest_of(described_class.key_provider(city_a).encryption_key))
      .not_to eq(digest_of(described_class.key_provider(city_b).encryption_key))
    expect(digest_of(described_class.deterministic_key_provider(city_a).encryption_key))
      .not_to eq(digest_of(described_class.deterministic_key_provider(city_b).encryption_key))
  end

  it "is stable for the same city" do
    expect(digest_of(described_class.key_provider(city_a).encryption_key))
      .to eq(digest_of(described_class.key_provider(city_a).encryption_key))
  end

  it "derives a stable deterministic key for the same city" do
    first = described_class.deterministic_key_provider(city_a)
    second = described_class.deterministic_key_provider(city_a)

    expect(digest_of(second.encryption_key)).to eq(digest_of(first.encryption_key))
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

  # A Global Constraint do plano é nunca expor material de chave: os métodos que
  # devolvem o segredo cru não podem ser chamáveis de fora do serviço.
  it "does not expose raw key material through its public surface" do
    expect(described_class).to respond_to(:context_properties, :key_provider, :deterministic_key_provider)
    expect(described_class).not_to respond_to(:secret_for)
    expect(described_class).not_to respond_to(:platform_primary_key)
    expect(described_class).not_to respond_to(:platform_deterministic_key)
  end
end
