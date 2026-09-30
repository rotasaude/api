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
