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
  # It depends on ActiveRecord::TestFixtures internals (@fixture_connection_pools,
  # #teardown_fixtures). If an upgrade removes them, it raises GuardInert instead
  # of silently doing nothing.
  #
  # Returns the released pool names, or nil when nothing leaked.
  class GuardInert < StandardError; end

  def self.release_leaked_fixture_transaction(example)
    instance = example.example.example_group_instance
    klass = instance.class
    unless klass.respond_to?(:use_transactional_tests)
      raise GuardInert, "#{klass} does not respond to use_transactional_tests; the leaked-fixture guard cannot run"
    end
    return unless klass.use_transactional_tests

    unless instance.instance_variable_defined?(:@fixture_connection_pools) && instance.respond_to?(:teardown_fixtures, true)
      raise GuardInert, "ActiveRecord::TestFixtures internals changed (@fixture_connection_pools / #teardown_fixtures); " \
                        "the leaked-fixture guard in spec/support/city_test_databases.rb must be updated"
    end

    pools = instance.instance_variable_get(:@fixture_connection_pools)
    return if pools.empty?

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
    original = nil
    leaked = nil
    begin
      CityConnection.with(TEST_CITY_A) { example.run }
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised unchanged
      original = e
      raise
    ensure
      begin
        leaked = CityTestDatabases.release_leaked_fixture_transaction(example)
      rescue StandardError => guard_error
        # Never replace the example's own exception with the guard's.
        raise guard_error unless original

        warn "[city harness] #{example.full_description}: leaked-fixture guard failed while " \
             "#{original.class} propagated — #{guard_error.class}: #{guard_error.message}"
      end
    end
    if leaked
      raise CityTestDatabases::LeakedFixtureTransaction,
            "fixture transaction was not torn down; released pools: #{leaked.join(', ')}"
    end
  end
end
