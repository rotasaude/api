require "rails_helper"
require Rails.root.join("db/city_migrate/20260930200001_create_analytics.rb").to_s

# F-14.1: o down() da migração de cidade 20260930200001 desfaz o que o up()
# cria (duas tabelas e o papel analyst no CHECK de memberships), e o up()
# seguinte restaura o schema idêntico. O down recusa quando já existe
# membership analyst: memberships não se apagam.
#
# Mesmo desenho de create_campaigns_migration_spec.rb (módulo 12): o DDL do
# Postgres é transacional, então down e up rodam num savepoint desfeito no fim
# e o banco de teste compartilhado nunca fica alterado.
RSpec.describe "Migração de cidade 20260930200001 (CreateAnalytics): down e up" do
  let(:new_tables) { %w[analytics_daily_facts analytics_runs] }
  let(:models) { [ AnalyticsDailyFact, AnalyticsRun, Membership ] }

  def conn = ApplicationRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateAnalytics.new.exec_migration(conn, direction) }
    models.each(&:reset_column_information)
  end

  def rows(sql) = conn.select_rows(sql)

  def fingerprint
    ignored = "('schema_migrations', 'ar_internal_metadata')"
    {
      columns: rows(<<~SQL),
        SELECT table_name, column_name, data_type, character_maximum_length::text, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name NOT IN #{ignored} ORDER BY 1, 2
      SQL
      indexes: rows(<<~SQL),
        SELECT tablename, indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename NOT IN #{ignored} ORDER BY 1, 2
      SQL
      constraints: rows(<<~SQL)
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND rel.relname NOT IN #{ignored} ORDER BY 1, 2
      SQL
    }
  end

  def roles_check(fp)
    fp[:constraints].find { |(table, name, _)| table == "memberships" && name == "ck_memberships_role" }&.third
  end

  def in_rolled_back_savepoint
    ApplicationRecord.transaction(requires_new: true) do
      yield
      raise ActiveRecord::Rollback
    end
  ensure
    models.each(&:reset_column_information)
  end

  it "down remove as tabelas e o papel; up seguinte restaura o schema idêntico" do
    in_rolled_back_savepoint do
      before = fingerprint
      expect(conn.tables).to include(*new_tables)
      expect(roles_check(before)).to include("'analyst'")
      expect(before[:indexes].find { |(_, name, _)| name == "idx_analytics_facts_cell" }&.third)
        .to include("NULLS NOT DISTINCT")

      migrate(:down)
      down = fingerprint

      expect(conn.tables & new_tables).to be_empty
      expect(roles_check(down)).not_to include("analyst")
      expect(roles_check(down)).to include("'campaign_manager'", "'viewer'")

      untouched = lambda do |fp|
        fp.transform_values do |list|
          list.reject { |row| row.join(" ").include?("analytics") || row.second == "ck_memberships_role" }
        end
      end
      expect(untouched.call(down)).to eq(untouched.call(before))

      migrate(:up)

      expect(fingerprint).to eq(before)
    end
  end

  it "down falha com membership analyst existente e não desfaz nada" do
    in_rolled_back_savepoint do
      staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br").tap do |user|
        sql_in_savepoint("INSERT INTO memberships (id, user_id, role, granted_at, created_at, updated_at) " \
                         "VALUES (gen_random_uuid(), '#{user.id}', 'analyst', now(), now(), now())")
      end
      before = fingerprint

      expect do
        ApplicationRecord.transaction(requires_new: true) { migrate(:down) }
      end.to raise_error(ActiveRecord::StatementInvalid, /ck_memberships_role/)

      models.each(&:reset_column_information)
      expect(fingerprint).to eq(before)
    end
  end
end
