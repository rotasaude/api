require "rails_helper"

RSpec.describe CityDeterministicKeyProvider do
  let(:city_a) { City.new(slug: "aaa", name: "A", status: "active", encryption_key: "a" * 64) }
  let(:city_b) { City.new(slug: "bbb", name: "B", status: "active", encryption_key: "b" * 64) }

  it "resolves the key of the city in Current at call time" do
    provider = described_class.new

    digest_a = Current.set(city: city_a) { Digest::SHA256.hexdigest(provider.encryption_key.secret) }
    digest_b = Current.set(city: city_b) { Digest::SHA256.hexdigest(provider.encryption_key.secret) }

    expect(digest_a).not_to eq(digest_b)
  end

  # Não chame decryption_keys com nil: KeyProvider#decryption_keys acessa
  # `message.headers` sem checar nil. A prova de leitura é o round-trip pelo
  # modelo, na Task 3.
  it "memoizes one provider per city material" do
    provider = described_class.new

    digest_first  = Current.set(city: city_a) { Digest::SHA256.hexdigest(provider.encryption_key.secret) }
    digest_second = Current.set(city: city_a) { Digest::SHA256.hexdigest(provider.encryption_key.secret) }
    digest_rotated = Current.set(city: City.new(slug: "aaa", name: "A", status: "active", encryption_key: "c" * 64)) do
      Digest::SHA256.hexdigest(provider.encryption_key.secret)
    end

    expect(digest_first).to eq(digest_second)
    expect(digest_rotated).not_to eq(digest_first)
  end

  it "fails closed outside a city" do
    provider = described_class.new
    Current.set(city: nil) do
      expect { provider.encryption_key }.to raise_error(CityEncryption::MissingKey)
    end
  end
end
