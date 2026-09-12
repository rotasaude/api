require "rails_helper"

# Herdeiro de spec/rls/tenant_isolation_spec.rb. Os invariantes são os mesmos;
# o mecanismo mudou de policy do Postgres para conexão por cidade.
#
# Pré-requisito: rails city:test_databases
RSpec.describe "City isolation", type: :model do
  class Probe < CityRecord
    self.table_name = "probes"
  end

  def url_for(db)
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432")
    pwd  = ENV.fetch("POSTGRES_PASSWORD", "postgres")
    "postgres://rota_saude:#{pwd}@#{host}:#{port}/#{db}"
  end

  let(:city_a) { build(:city, slug: "isoa", database_url: url_for("rota_saude_test_city_a")) }
  let(:city_b) { build(:city, slug: "isob", database_url: url_for("rota_saude_test_city_b")) }

  before do
    [city_a, city_b].each do |c|
      CityConnection.with(c) { Probe.delete_all }
    end
  end

  it "does not see rows written in another city" do
    CityConnection.with(city_a) { Probe.create!(label: "de-a") }
    CityConnection.with(city_b) { Probe.create!(label: "de-b") }

    expect(CityConnection.with(city_a) { Probe.pluck(:label) }).to eq(["de-a"])
    expect(CityConnection.with(city_b) { Probe.pluck(:label) }).to eq(["de-b"])
  end

  it "writes land in the city that is connected" do
    CityConnection.with(city_a) { Probe.create!(label: "so-em-a") }
    expect(CityConnection.with(city_b) { Probe.count }).to eq(0)
  end

  it "keeps concurrent readers on their own city" do
    CityConnection.with(city_a) { Probe.create!(label: "de-a") }
    CityConnection.with(city_b) { Probe.create!(label: "de-b") }

    errors = Queue.new
    threads = 20.times.map do |i|
      Thread.new do
        city, want = i.even? ? [city_a, "de-a"] : [city_b, "de-b"]
        20.times do
          got = CityConnection.with(city) { Probe.pluck(:label) }
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
    ghost = build(:city, slug: "fantasma", database_url: url_for("banco_que_nao_existe"))

    # CityConnection.with registers the pool (establish_connection succeeds —
    # the URL is well-formed) before the failure surfaces on first checkout.
    # That pool is process-global and is NOT rolled back by a transaction, so
    # left registered it would break every other spec's transactional fixture
    # setup, which pins every writing pool across every shard on CityRecord.
    # Deregister it here, regardless of outcome, so this example proves the
    # fail-closed invariant without poisoning the rest of the suite.
    begin
      expect { CityConnection.with(ghost) { Probe.count } }
        .to raise_error(ActiveRecord::NoDatabaseError)
    ensure
      ActiveRecord::Base.connection_handler
        .remove_connection_pool(CityRecord.name, role: :writing, shard: ghost.shard)
    end
  end
end
