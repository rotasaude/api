require "rails_helper"
require Rails.root.join("db/city_migrate/20260929100001_create_campaigns.rb").to_s
require Rails.root.join("db/city_migrate/20260930200001_create_analytics.rb").to_s
require Rails.root.join("db/city_migrate/20261002300001_create_appointment_reminders.rb").to_s

# F-12.1/F-12.3: o down() da migração de cidade 20260929100001 desfaz tudo o que
# o up() cria (três tabelas, a coluna da chave de SMS, as duas funções de guarda
# com seus triggers e o papel campaign_manager no CHECK de memberships), e o
# up() seguinte restaura o schema idêntico. O down recusa quando já existe
# membership campaign_manager: memberships não se apagam.
#
# Mesmo desenho de create_territory_migration_spec.rb (módulo 11): o DDL do
# Postgres é transacional, então down e up rodam num savepoint desfeito no fim
# (além da transação de fixture) e o banco de teste compartilhado nunca fica
# alterado. O retrato do schema é lido pela MESMA conexão.
RSpec.describe "Migração de cidade 20260929100001 (CreateCampaigns): down e up" do
  let(:new_tables) { %w[campaigns campaign_recipients citizen_contact_preferences] }
  let(:new_column) { %w[city_profile campaigns_sms_enabled] }
  let(:new_triggers) { %w[campaigns_frozen_after_send campaign_recipients_append_only] }
  let(:new_functions) { %w[rota_campaign_guard rota_campaign_recipient_guard] }
  let(:models) { [ Campaign, CampaignRecipient, CitizenContactPreference, CityProfile, Membership ] }

  def conn = ApplicationRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateCampaigns.new.exec_migration(conn, direction) }
    models.each(&:reset_column_information)
  end

  # CreateCampaigns#up reescreve ck_memberships_role com uma lista fixa, sem
  # analyst (módulo 14): dentro do savepoint, a migração do Analytics sai antes
  # do down/up de campanhas e volta depois, para a igualdade do schema valer.
  def migrate_analytics(direction)
    ActiveRecord::Migration.suppress_messages { CreateAnalytics.new.exec_migration(conn, direction) }
    models.each(&:reset_column_information)
  end

  # 20261002300001 (api#39) acrescenta appointment_reminders_muted a
  # citizen_contact_preferences, que o down de CreateCampaigns derruba: sai
  # antes e volta depois, como o analytics.
  def migrate_reminders(direction)
    ActiveRecord::Migration.suppress_messages { CreateAppointmentReminders.new.exec_migration(conn, direction) }
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
      constraints: rows(<<~SQL),
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND rel.relname NOT IN #{ignored} ORDER BY 1, 2
      SQL
      triggers: rows(<<~SQL),
        SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid)
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND NOT t.tgisinternal AND c.relname NOT IN #{ignored} ORDER BY 1, 2
      SQL
      functions: rows(<<~SQL)
        SELECT p.proname, pg_get_functiondef(p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.prokind = 'f' ORDER BY 1, 2
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

  it "down remove tabelas, coluna, triggers, funções e o papel; up seguinte restaura o schema idêntico" do
    in_rolled_back_savepoint do
      before = fingerprint
      expect(conn.tables).to include(*new_tables)
      expect(before[:columns].map { _1.first(2) }).to include(new_column)
      expect(before[:triggers].map(&:second)).to include(*new_triggers)
      expect(before[:functions].map(&:first)).to include(*new_functions)
      expect(roles_check(before)).to include("'campaign_manager'")

      migrate_reminders(:down)
      migrate_analytics(:down)
      migrate(:down)
      down = fingerprint

      expect(conn.tables & new_tables).to be_empty
      expect(down[:columns].map { _1.first(2) }).not_to include(new_column)
      expect(down[:triggers].map(&:second) & new_triggers).to be_empty
      expect(down[:functions].map(&:first) & new_functions).to be_empty
      expect(roles_check(down)).not_to include("campaign_manager")
      expect(roles_check(down)).to include("'protocol_reviewer'", "'viewer'")
      # O papel sumido é recusado pelo CHECK de volta à forma anterior.
      user = User.create!(email_address: "migracao-#{SecureRandom.hex(3)}@cidade.gov.br", password: "senha-segura-123")
      expect do
        ApplicationRecord.transaction(requires_new: true) do
          Membership.create!(user: user, role: "campaign_manager", granted_at: Time.current)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /ck_memberships_role/)

      # O down só tira o que é do módulo 12: o resto do schema segue intacto.
      untouched = lambda do |fp|
        fp.transform_values do |list|
          list.reject do |row|
            text = row.join(" ")
            text.include?("campaign") || text.include?("citizen_contact_preferences") ||
              text.include?("analytics") || text.include?("appointment_reminder") ||
              row.second == "ck_memberships_role"
          end
        end
      end
      expect(untouched.call(down)).to eq(untouched.call(before))

      migrate(:up)
      migrate_analytics(:up)
      migrate_reminders(:up)

      expect(fingerprint).to eq(before)
      # O trigger restaurado segue recusando apagar campanha que não é rascunho.
      campaign = sent_campaign!
      expect do
        ApplicationRecord.transaction(requires_new: true) { campaign.delete }
      end.to raise_error(ActiveRecord::StatementInvalid, /only a draft may be deleted/)
    end
  end

  it "down falha com membership campaign_manager existente e não desfaz nada" do
    in_rolled_back_savepoint do
      staff_with("gestor-#{SecureRandom.hex(3)}@cidade.gov.br", "campaign_manager")
      before = fingerprint

      expect do
        ApplicationRecord.transaction(requires_new: true) { migrate(:down) }
      end.to raise_error(ActiveRecord::StatementInvalid, /ck_memberships_role/)

      models.each(&:reset_column_information)
      expect(fingerprint).to eq(before)
      expect(Membership.where(role: "campaign_manager").count).to eq(1)
    end
  end
end
