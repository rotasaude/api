require "rails_helper"

# Schema dos bancos de cidade (spec banco-por-cidade §4, Plano 4). Os exemplos que
# migram usam um banco descartável DE VERDADE: DDL dentro da transação de fixture
# seria desfeito e invisível às outras conexões.
RSpec.describe CitySchema do
  self.use_transactional_tests = false

  let(:scratch) { ScratchDatabases.new_name }

  after { ScratchDatabases.drop!(scratch) }

  def versions_on_disk
    Dir[Rails.root.join("db/city_migrate/*.rb").to_s].map { |f| File.basename(f).to_i }.sort
  end

  def recorded_versions(database)
    ScratchDatabases.superuser(database) { |c| c.exec("SELECT version FROM schema_migrations ORDER BY 1").column_values(0).map(&:to_i) }
  end

  it "keeps sslmode from the city URL query in the ad-hoc config" do
    expect(described_class.db_config_for("postgres://u:p@h:5432/d?sslmode=require").configuration_hash[:sslmode])
      .to eq("require")
  end

  it "expects the highest version in db/city_migrate" do
    expect(described_class.expected_version).to eq(versions_on_disk.max)
  end

  it "migrates an empty database from zero to the expected version, and the second run is a no-op" do
    ScratchDatabases.create!(scratch)
    url = ScratchDatabases.url(scratch)

    expect(described_class.migrate!(url)).to eq(described_class.expected_version)
    expect(described_class.migrate!(url)).to eq(described_class.expected_version)
    expect(described_class.current_version(url)).to eq(described_class.expected_version)
    expect(recorded_versions(scratch)).to eq(versions_on_disk)
  end

  it "gives ActiveRecord::Base back its own database after migrating a city" do
    ScratchDatabases.create!(scratch)
    original = ActiveRecord::Base.connection_db_config.database

    described_class.migrate!(ScratchDatabases.url(scratch))

    expect(ActiveRecord::Base.connection_db_config.database).to eq(original)
  end

  # O dump db/city_schema.rb (city:test_databases, city:dev_up) e as migrations
  # (provisionamento, rollout) precisam produzir o MESMO schema.
  # rota_saude_test_city_b é carregado pelo dump.
  it "produces from the migrations exactly the schema of db/city_schema.rb" do
    ScratchDatabases.create!(scratch)
    described_class.migrate!(ScratchDatabases.url(scratch))

    expect(schema_fingerprint(scratch)).to eq(schema_fingerprint("rota_saude_test_city_b"))
  end

  it "backfills versions below the highest recorded one and never records a higher one" do
    ScratchDatabases.create!(scratch)
    url = ScratchDatabases.url(scratch)
    described_class.migrate!(url)
    lowest, highest = versions_on_disk.first, versions_on_disk.last

    ScratchDatabases.superuser(scratch) { |c| c.exec("DELETE FROM schema_migrations WHERE version <> '#{highest}'") }
    expect(described_class.backfill_versions!(url)).to eq(highest)
    expect(recorded_versions(scratch)).to eq(versions_on_disk)

    ScratchDatabases.superuser(scratch) { |c| c.exec("DELETE FROM schema_migrations WHERE version <> '#{lowest}'") }
    expect(described_class.backfill_versions!(url)).to eq(lowest)
    expect(recorded_versions(scratch)).to eq([ lowest ])
  end

  it "redacts the credentials of any database URL in a message" do
    text = "falhou em postgres://rota_city_x:s3gr3d0@db:5432/rota_saude_city_x e postgresql://u:p@h/d"

    expect(described_class.redact(text)).to eq("falhou em postgres://***@db:5432/rota_saude_city_x e postgresql://***@h/d")
  end

  describe ".behind?" do
    it "is true when the catalog records a lower version, or none, and false when it is current" do
      expected = described_class.expected_version

      expect(described_class.behind?(City.new(schema_version: (expected - 1).to_s))).to be(true)
      expect(described_class.behind?(City.new(schema_version: nil))).to be(true)
      expect(described_class.behind?(City.new(schema_version: expected.to_s))).to be(false)
    end
  end

  def schema_fingerprint(database)
    ignored = "('probes', 'schema_migrations', 'ar_internal_metadata')"
    ScratchDatabases.superuser(database) do |conn|
      {
        columns: conn.exec(<<~SQL).values,
          SELECT table_name, column_name, data_type, is_nullable, column_default
          FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name NOT IN #{ignored}
          ORDER BY 1, 2
        SQL
        indexes: conn.exec(<<~SQL).values,
          SELECT tablename, indexname, indexdef FROM pg_indexes
          WHERE schemaname = 'public' AND tablename NOT IN #{ignored}
          ORDER BY 1, 2
        SQL
        constraints: conn.exec(<<~SQL).values
          SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
          JOIN pg_namespace ns ON ns.oid = rel.relnamespace
          WHERE ns.nspname = 'public' AND rel.relname NOT IN #{ignored}
          ORDER BY 1, 2
        SQL
      }
    end
  end
end
