# Harness de banco por cidade para a suíte.
#
# Cada exemplo roda dentro da conexão de uma cidade de teste. Specs que precisam
# de duas cidades (isolamento) usam `within_city`.
#
# Pré-requisito: rails city:test_databases
module CityTestDatabases
  def self.city(slug, db)
    City.new(slug: slug, name: slug.capitalize, status: "active",
             database_url: CityDatabaseUrls.city_database_url(db), encryption_key: SecureRandom.hex(32))
  end

  def within_city(city, &block)
    CityConnection.with(city, &block)
  end
end

TEST_CITY_A = CityTestDatabases.city("testcitya", "rota_saude_test_city_a").freeze
TEST_CITY_B = CityTestDatabases.city("testcityb", "rota_saude_test_city_b").freeze

class CityHarnessProbe < CityRecord
  self.table_name = "probes"
end

RSpec.configure do |config|
  config.include CityTestDatabases

  config.around(:each) do |example|
    CityConnection.with(TEST_CITY_A) { example.run }
  end
end
