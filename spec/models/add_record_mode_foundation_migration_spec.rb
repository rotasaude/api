# spec/models/add_record_mode_foundation_migration_spec.rb
require "rails_helper"
require Rails.root.join("db/city_migrate/20261005200001_add_record_mode_foundation.rb").to_s

# ADR 0028: down desfaz o que up cria; up seguinte restaura idêntico. Savepoint.
RSpec.describe "Migração de cidade 20261005200001 (AddRecordModeFoundation): down e up" do
  let(:models) { [ IntegrationCredential, HealthTeam, HealthTeamMember, HealthUnit, Professional, Citizen ] }

  def conn = ApplicationRecord.connection

  # Migrações posteriores com FK para as tabelas desta: as do módulo 23
  # (20261022900002: care_line_enrollments.team_id e
  # care_line_suggestions.team_id → health_teams) são irreversíveis, então não
  # saem pelo down delas como no padrão LATER (add_triage_catalog). As FKs
  # delas saem antes do down e voltam depois do up com o mesmo nome e a mesma
  # definição; o fingerprint (tirado antes) confere que voltaram idênticas.
  # Lida do catálogo: uma FK nova de migração futura entra sozinha.
  def later_foreign_keys
    conn.select_rows(<<~SQL)
      SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid JOIN pg_class ref ON ref.oid = con.confrelid
      WHERE con.contype = 'f' AND ref.relname IN ('integration_credentials', 'health_teams', 'health_team_members')
        AND rel.relname NOT IN ('integration_credentials', 'health_teams', 'health_team_members')
      ORDER BY 1, 2
    SQL
  end

  def migrate(direction, later)
    ActiveRecord::Migration.suppress_messages do
      if direction == :down
        later.each { |table, name, _| conn.execute("ALTER TABLE #{conn.quote_table_name(table)} DROP CONSTRAINT #{conn.quote_column_name(name)}") }
        AddRecordModeFoundation.new.exec_migration(conn, :down)
      else
        AddRecordModeFoundation.new.exec_migration(conn, :up)
        later.each do |table, name, definition|
          conn.execute("ALTER TABLE #{conn.quote_table_name(table)} ADD CONSTRAINT #{conn.quote_column_name(name)} #{definition}")
        end
      end
    end
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
      later = later_foreign_keys
      expect(later.map { |table, _, _| table }).to include("care_line_enrollments", "care_line_suggestions")
      migrate(:down, later)
      expect(conn.tables & %w[integration_credentials health_teams health_team_members]).to be_empty
      expect(conn.columns(:citizens).map(&:name)).not_to include("cns", "cadsus_checked_at", "cadsus_pending_cns")
      migrate(:up, later)
      expect(fingerprint).to eq(before)
      raise ActiveRecord::Rollback
    end
  ensure
    models.each(&:reset_column_information)
  end
end
