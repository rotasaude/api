require "rails_helper"
require Rails.root.join("db/platform_migrate/20260930200002_create_city_analytics_indicators.rb").to_s

# F-14.8: a migração de plataforma é reversível — down remove a tabela (e a FK),
# up a restaura idêntica. Num savepoint da conexão de plataforma, desfeito no
# fim: o banco de plataforma de teste nunca fica alterado.
RSpec.describe "Migração de plataforma 20260930200002 (CreateCityAnalyticsIndicators): down e up" do
  def conn = PlatformRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateCityAnalyticsIndicators.new.exec_migration(conn, direction) }
    CityAnalyticsIndicator.reset_column_information
  end

  def fingerprint
    ignored = "('schema_migrations', 'ar_internal_metadata')"
    {
      columns: conn.select_rows(<<~SQL),
        SELECT table_name, column_name, data_type, numeric_precision::text, numeric_scale::text, is_nullable, column_default
        FROM information_schema.columns WHERE table_schema = 'public' AND table_name NOT IN #{ignored} ORDER BY 1, 2
      SQL
      indexes: conn.select_rows(<<~SQL),
        SELECT tablename, indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename NOT IN #{ignored} ORDER BY 1, 2
      SQL
      constraints: conn.select_rows(<<~SQL)
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND rel.relname NOT IN #{ignored} ORDER BY 1, 2
      SQL
    }
  end

  # api#38: na CI o banco de plataforma nasce de db/platform_schema.rb, aqui das
  # migrações. Se a regra escrita pela migração e a guardada no dump não forem o
  # mesmo texto depois que o Postgres as normaliza, o down/up abaixo só falha lá.
  def deparse(expression)
    conn.execute("CREATE TEMP TABLE api38_check (indicator varchar NOT NULL, CONSTRAINT api38_k CHECK (#{expression}))")
    conn.select_value(<<~SQL)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conname = 'api38_k' AND conrelid = 'api38_check'::regclass
    SQL
  ensure
    conn.execute("DROP TABLE IF EXISTS api38_check")
  end

  it "a regra de indicador criada pela migração é a mesma que o schema da plataforma carrega" do
    dumped = File.read(Rails.root.join("db/platform_schema.rb"))[
      /check_constraint "([^"]+)", name: "ck_city_analytics_indicators_indicator"/, 1
    ]
    expect(dumped).to be_present

    PlatformRecord.transaction(requires_new: true) do
      migrate(:down)
      migrate(:up)
      created = conn.select_value(<<~SQL)
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conname = 'ck_city_analytics_indicators_indicator'
      SQL
      expect(created).to eq(deparse(dumped))
      raise ActiveRecord::Rollback
    end
  ensure
    CityAnalyticsIndicator.reset_column_information
  end

  it "down remove a tabela e a FK; up seguinte restaura o schema idêntico" do
    PlatformRecord.transaction(requires_new: true) do
      before = fingerprint
      expect(conn.table_exists?(:city_analytics_indicators)).to be(true)

      migrate(:down)
      expect(conn.table_exists?(:city_analytics_indicators)).to be(false)

      migrate(:up)
      expect(fingerprint).to eq(before)
      raise ActiveRecord::Rollback
    end
  ensure
    CityAnalyticsIndicator.reset_column_information
  end
end
