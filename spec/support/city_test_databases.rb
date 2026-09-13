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

  class LeakedFixtureTransaction < StandardError; end

  # rspec-rails' MinitestLifecycleAdapter wraps every example as
  #
  #   around { before_setup; example.run; after_teardown }
  #
  # with no `ensure`. An exception raised by a spec-level `around` hook (which
  # runs inside that one) propagates past `example.run` and skips
  # teardown_transactional_fixtures: every writing pool stays pinned inside a
  # real transaction that is never rolled back, and the `!connection` subscriber
  # keeps pinning pools established later. Every following example on the
  # thread then runs inside that stale transaction; the first SQL error aborts
  # it and the rest of the suite fails with PG::InFailedSqlTransaction
  # (Task 5c-1: 810 of them, triggered by `around` hooks that raised on the
  # removed Municipality/`Current.municipality_id` before `ex.run`).
  #
  # This guard runs outside the adapter's hook, in an `ensure`: the exception
  # that skipped teardown also propagates through this hook, so code placed
  # after `example.run` would never run. It runs the teardown Rails skipped,
  # so the leak cannot cascade; the example still fails with the original
  # exception. A leak with no exception fails the example with
  # LeakedFixtureTransaction.
  #
  # Returns the released pool names, or nil when nothing leaked.
  def self.release_leaked_fixture_transaction(example)
    instance = example.example.example_group_instance
    pools = instance&.instance_variable_get(:@fixture_connection_pools)
    return if pools.blank?

    names = pools.map { |pool| "#{pool.connection_descriptor.name}/#{pool.shard}" }
    instance.send(:teardown_fixtures)
    names
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
    leaked = nil
    begin
      CityConnection.with(TEST_CITY_A) { example.run }
    ensure
      leaked = CityTestDatabases.release_leaked_fixture_transaction(example)
    end
    if leaked
      raise CityTestDatabases::LeakedFixtureTransaction,
            "fixture transaction was not torn down; released pools: #{leaked.join(', ')}"
    end
  end
end
