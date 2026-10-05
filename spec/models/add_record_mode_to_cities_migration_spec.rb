require "rails_helper"
require Rails.root.join("db/platform_migrate/20261005200001_add_record_mode_to_cities.rb").to_s

# ADR 0028: a migração de plataforma é reversível — down remove colunas, CHECKs
# e a tabela; up restaura o schema idêntico. Num savepoint da plataforma.
RSpec.describe "Migração de plataforma 20261005200001 (AddRecordModeToCities): down e up" do
  def conn = PlatformRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { AddRecordModeToCities.new.exec_migration(conn, direction) }
    [ City, CityFeature ].each(&:reset_column_information)
  end

  def fingerprint
    ignored = "('schema_migrations', 'ar_internal_metadata')"
    {
      columns: conn.select_rows(<<~SQL),
        SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name NOT IN #{ignored} ORDER BY 1, 2
      SQL
      indexes: conn.select_rows("SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1, 2"),
      constraints: conn.select_rows(<<~SQL)
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' ORDER BY 1, 2
      SQL
    }
  end

  it "down remove o que up cria; up seguinte restaura idêntico" do
    PlatformRecord.transaction(requires_new: true) do
      before = fingerprint
      migrate(:down)
      expect(conn.table_exists?(:city_features)).to be(false)
      expect(conn.columns(:cities).map(&:name)).not_to include("record_mode", "pec_url")
      migrate(:up)
      expect(fingerprint).to eq(before)
      raise ActiveRecord::Rollback
    end
  ensure
    [ City, CityFeature ].each(&:reset_column_information)
  end
end
