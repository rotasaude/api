require "rails_helper"
require Rails.root.join("db/city_migrate/20261005100001_add_triage_catalog.rb").to_s

# F-15.1/F-15.4: o down() da migração de cidade 20261005100001 desfaz o que o
# up() cria, e o up() seguinte restaura o schema idêntico. DDL do Postgres é
# transacional: down e up rodam num savepoint desfeito no fim.
RSpec.describe "Migração de cidade 20261005100001 (AddTriageCatalog): down e up" do
  let(:new_tables) { %w[triage_offers triage_suggestions triage_offer_daily_counts] }
  let(:models) { [ Citizen, TriageOffer, TriageSuggestion, TriageOfferDailyCount ] }

  def conn = ApplicationRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { AddTriageCatalog.new.exec_migration(conn, direction) }
    models.each(&:reset_column_information)
  end

  def fingerprint
    {
      columns: conn.select_rows(<<~SQL),
        SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name NOT IN ('schema_migrations', 'ar_internal_metadata') ORDER BY 1, 2
      SQL
      indexes: conn.select_rows("SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1, 2"),
      constraints: conn.select_rows(<<~SQL)
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' ORDER BY 1, 2
      SQL
    }
  end

  it "down remove tabelas e colunas; up seguinte restaura o schema idêntico" do
    ApplicationRecord.transaction(requires_new: true) do
      before = fingerprint
      migrate(:down)
      expect(conn.tables & new_tables).to be_empty
      expect(conn.columns(:citizens).map(&:name)).not_to include("birth_date", "sex", "gender_identity", "profile_source")
      migrate(:up)
      expect(fingerprint).to eq(before)
      raise ActiveRecord::Rollback
    end
  ensure
    models.each(&:reset_column_information)
  end
end
