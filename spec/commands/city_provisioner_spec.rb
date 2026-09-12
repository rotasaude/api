require "rails_helper"

RSpec.describe CityProvisioner do
  before { City.delete_all }

  it "registers a city in the catalog as provisioning" do
    result = described_class.call(slug: "novacidade", name: "Nova Cidade", uf: "SP")
    city = result.payload[:city]

    expect(result.ok?).to be true
    expect(city).to be_persisted
    expect(city.status).to eq("provisioning")
    expect(city.database_url).to include("rota_saude_city_novacidade")
    expect(city.encryption_key.length).to eq(64)
  end

  it "is idempotent on slug" do
    first  = described_class.call(slug: "repetida", name: "Repetida", uf: "SP")
    second = described_class.call(slug: "repetida", name: "Repetida", uf: "SP")
    expect(second.payload[:city].id).to eq(first.payload[:city].id)
    expect(City.where(slug: "repetida").count).to eq(1)
  end

  it "rejects a slug that is not a DNS label" do
    result = described_class.call(slug: "Nao Vale", name: "X", uf: "SP")

    expect(result.failure?).to be true
    expect(result.reason).to eq(:invalid)
    expect(result.message).to match(/slug/i)
  end

  it "returns Result.ok, not a raised error, when a duplicate slug is created concurrently" do
    # ADR-0004: a Command returns a Result, never raises, for an expected
    # failure. The find_by/create! pair in .call is a TOCTOU — simulate the
    # race by having the first find_by miss (like the real check) and the
    # create! collide with a row that landed between the two calls.
    concurrent = create(:city, slug: "concorrente")
    allow(City).to receive(:find_by).with(slug: "concorrente").and_return(nil, concurrent)
    allow(City).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))

    result = described_class.call(slug: "concorrente", name: "Concorrente", uf: "SP")

    expect(result.ok?).to be true
    expect(result.payload[:city]).to eq(concurrent)
  end

  it "aborts if POSTGRES_PASSWORD is not set" do
    original = ENV.delete("POSTGRES_PASSWORD")
    expect { described_class.database_url_for("qualquer") }.to raise_error(SystemExit)
  ensure
    ENV["POSTGRES_PASSWORD"] = original
  end
end
