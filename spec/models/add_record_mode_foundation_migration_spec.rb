# spec/models/add_record_mode_foundation_migration_spec.rb
require "rails_helper"
require Rails.root.join("db/city_migrate/20261005200001_add_record_mode_foundation.rb").to_s

# ADR 0028: down desfaz o que up cria; up seguinte restaura idêntico. Savepoint.
RSpec.describe "Migração de cidade 20261005200001 (AddRecordModeFoundation): down e up" do
  let(:models) { [ IntegrationCredential, HealthTeam, HealthTeamMember, HealthUnit, Professional, Citizen ] }

  def conn = ApplicationRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { AddRecordModeFoundation.new.exec_migration(conn, direction) }
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

  it "down remove tabelas e colunas; up restaura idêntico" do
    ApplicationRecord.transaction(requires_new: true) do
      before = fingerprint
      migrate(:down)
      expect(conn.tables & %w[integration_credentials health_teams health_team_members]).to be_empty
      expect(conn.columns(:citizens).map(&:name)).not_to include("cns", "cadsus_checked_at", "cadsus_pending_cns")
      migrate(:up)
      expect(fingerprint).to eq(before)
      raise ActiveRecord::Rollback
    end
  ensure
    models.each(&:reset_column_information)
  end
end
