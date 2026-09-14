require "rails_helper"

RSpec.describe CityConnection do
  # Cada exemplo usa sua própria cidade, com slug único: o connection handler
  # é global ao processo e pools registrados por um exemplo sobrevivem
  # (não são desfeitos pela transação), então dois exemplos não podem
  # compartilhar shard — um exemplo que reusasse o shard de outro encontraria
  # o pool já registrado por ele, invalidando asserções como "ainda não
  # registrado" independentemente da ordem em que os exemplos rodam.
  def db_host
    ENV.fetch("DATABASE_HOST", "127.0.0.1")
  end

  def build_city(slug: "conn#{SecureRandom.hex(4)}", **attrs)
    build(:city, slug: slug,
          database_url: ENV.fetch("TEST_CITY_A_URL", city_database_url("rota_saude_test_city_a")),
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

  it "raises for a city whose database_url has an adapter scheme that does not exist" do
    # AdapterNotFound is raised by establish_connection itself (validate!),
    # not by config resolution — this only reaches the registry's rescue
    # because it now wraps the whole registration, not just db_config_for.
    secret = "hunter2-#{SecureRandom.hex(3)}"
    broken = build_city(slug: "adptr#{SecureRandom.hex(4)}",
      database_url: "postgress://rota_saude:#{secret}@#{db_host}:5432/rota_saude_test_city_a")

    expect { described_class.with(broken) { 1 } }
      .to raise_error(CityConnection::InvalidCityDatabase) { |error|
        expect(error.message).to include(broken.slug)
        expect(error.message).not_to include(secret)
      }
  end

  it "forgets a registered pool" do
    city = build_city
    described_class.ensure_pool(city)
    expect(described_class.registered?(city.shard)).to be(true)

    described_class.forget(city.shard)

    expect(described_class.registered?(city.shard)).to be(false)
  end

  it "raises for a city whose database_url cannot be parsed as a URI" do
    broken = build_city(slug: "uriparse#{SecureRandom.hex(4)}",
      database_url: "postgres://rota_saude:pa[sswd@#{db_host}:5432/rota_saude_test_city_a")

    expect { described_class.with(broken) { 1 } }
      .to raise_error(CityConnection::InvalidCityDatabase, /#{broken.slug}/)
  end
end
