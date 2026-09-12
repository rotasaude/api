require "rails_helper"

RSpec.describe CityConnection do
  # Cada exemplo usa sua própria cidade, com slug único: o connection handler
  # é global ao processo e pools registrados por um exemplo sobrevivem
  # (não são desfeitos pela transação), então dois exemplos não podem
  # compartilhar shard sob config.order = :random (spec_helper.rb).
  def build_city(slug: "conn#{SecureRandom.hex(4)}", **attrs)
    build(:city, slug: slug,
          database_url: ENV.fetch("TEST_CITY_A_URL",
            "postgres://rota_saude:postgres@127.0.0.1:5432/rota_saude_test_city_a"),
          **attrs)
  end

  it "registers a pool on first use and reuses it afterwards" do
    city = build_city
    expect(described_class.registered?(city.shard)).to be(false)
    described_class.ensure_pool(city)
    expect(described_class.registered?(city.shard)).to be(true)

    pool = ActiveRecord::Base.connection_handler
             .retrieve_connection_pool(CityRecord.name, role: :writing, shard: city.shard)
    described_class.ensure_pool(city)
    expect(ActiveRecord::Base.connection_handler
             .retrieve_connection_pool(CityRecord.name, role: :writing, shard: city.shard))
      .to equal(pool)
  end

  it "runs the block against the city's database" do
    city = build_city
    result = described_class.with(city) { CityRecord.connection_db_config.database }
    expect(result).to eq("rota_saude_test_city_a")
  end

  it "raises for a city whose pool cannot be built" do
    broken = build_city(slug: "quebrada", database_url: "not-a-url")
    expect { described_class.with(broken) { 1 } }
      .to raise_error(CityConnection::InvalidCityDatabase, /quebrada/)
  end
end
