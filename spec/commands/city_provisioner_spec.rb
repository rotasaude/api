require "rails_helper"

RSpec.describe CityProvisioner do
  before { City.delete_all }

  it "registers a city in the catalog as provisioning" do
    city = described_class.call(slug: "novacidade", name: "Nova Cidade", uf: "SP")

    expect(city).to be_persisted
    expect(city.status).to eq("provisioning")
    expect(city.database_url).to include("rota_saude_city_novacidade")
    expect(city.encryption_key.length).to eq(64)
  end

  it "is idempotent on slug" do
    first  = described_class.call(slug: "repetida", name: "Repetida", uf: "SP")
    second = described_class.call(slug: "repetida", name: "Repetida", uf: "SP")
    expect(second.id).to eq(first.id)
    expect(City.where(slug: "repetida").count).to eq(1)
  end

  it "rejects a slug that is not a DNS label" do
    expect { described_class.call(slug: "Nao Vale", name: "X", uf: "SP") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
