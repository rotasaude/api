require "rails_helper"

# Herdeiro de spec/rls/tenant_isolation_spec.rb. Os invariantes são os mesmos;
# o mecanismo mudou de policy do Postgres para conexão por cidade.
#
# Pré-requisito: rails city:test_databases
RSpec.describe "City isolation", type: :model do
  # Spec-scoped name, not `Probe`: `class Probe < CityRecord` inside a
  # `describe` block still defines the constant at the top level (the
  # `class` keyword resolves its own lexical scope, which for a block is
  # Object) — the same class of collision fixed for SELF_PATH above.
  class CityIsolationProbe < CityRecord
    self.table_name = "probes"
  end

  let(:city_a) { build(:city, slug: "isoa", database_url: city_database_url("rota_saude_test_city_a")) }
  let(:city_b) { build(:city, slug: "isob", database_url: city_database_url("rota_saude_test_city_b")) }

  before do
    [city_a, city_b].each do |c|
      CityConnection.with(c) { CityIsolationProbe.delete_all }
    end
  end

  it "does not see rows written in another city" do
    CityConnection.with(city_a) { CityIsolationProbe.create!(label: "de-a") }
    CityConnection.with(city_b) { CityIsolationProbe.create!(label: "de-b") }

    expect(CityConnection.with(city_a) { CityIsolationProbe.pluck(:label) }).to eq(["de-a"])
    expect(CityConnection.with(city_b) { CityIsolationProbe.pluck(:label) }).to eq(["de-b"])
  end

  it "writes land in the city that is connected" do
    CityConnection.with(city_a) { CityIsolationProbe.create!(label: "so-em-a") }
    expect(CityConnection.with(city_b) { CityIsolationProbe.count }).to eq(0)
  end

  it "keeps concurrent readers on their own city" do
    CityConnection.with(city_a) { CityIsolationProbe.create!(label: "de-a") }
    CityConnection.with(city_b) { CityIsolationProbe.create!(label: "de-b") }

    errors = Queue.new
    threads = 20.times.map do |i|
      Thread.new do
        city, want = i.even? ? [city_a, "de-a"] : [city_b, "de-b"]
        20.times do
          got = CityConnection.with(city) { CityIsolationProbe.pluck(:label) }
          errors << "#{city.slug} leu #{got.inspect}" unless got == [want]
        end
      rescue => e
        errors << "#{city.slug} -> #{e.class}: #{e.message}"
      end
    end
    threads.each(&:join)

    expect(errors.size).to eq(0), "cruzamento entre cidades: #{errors.pop unless errors.empty?}"
  end

  it "fails closed for a city that was never registered" do
    ghost = build(:city, slug: "fantasma", database_url: city_database_url("banco_que_nao_existe"))

    # CityConnection.with registers the pool (establish_connection succeeds —
    # the URL is well-formed) before the failure surfaces on first checkout.
    # That pool is process-global and is NOT rolled back by a transaction, so
    # left registered it would break every other spec's transactional fixture
    # setup, which pins every writing pool across every shard on CityRecord.
    # Deregister it here, regardless of outcome, so this example proves the
    # fail-closed invariant without poisoning the rest of the suite.
    begin
      expect { CityConnection.with(ghost) { CityIsolationProbe.count } }
        .to raise_error(ActiveRecord::NoDatabaseError)
    ensure
      CityConnection.forget(ghost.shard)
    end
  end
end
