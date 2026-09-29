# db/city_migrate/20260929100001_create_campaigns.rb
# Campanhas (ADR 0024; spec 2026-09-29-module-12-campaigns §3): a campanha, o
# público congelado no envio (campaign_recipients), as preferências de contato
# do cidadão, a chave de SMS da cidade e o papel campaign_manager. Triggers em
# db/city_triggers.sql, a mesma fonte que load_city_schema executa depois de
# carregar o dump. Só expansão: nada existente muda de forma.
class CreateCampaigns < ActiveRecord::Migration[8.1]
  ROLES_BEFORE = %w[citizen_verifier health_professional municipal_admin protocol_author protocol_publisher
                    protocol_reviewer viewer].freeze
  ROLES_AFTER = %w[campaign_manager citizen_verifier health_professional municipal_admin protocol_author
                   protocol_publisher protocol_reviewer viewer].freeze

  def up
    replace_roles_check(ROLES_AFTER)

    add_column :city_profile, :campaigns_sms_enabled, :boolean, null: false, default: false

    create_table :campaigns, id: :uuid do |t|
      t.string :title, limit: 120, null: false
      t.text :body, null: false
      t.jsonb :audience, null: false
      t.string :status, null: false, default: "draft"
      t.datetime :send_at
      t.string :failure_reason
      t.boolean :sms_enabled
      t.integer :recipients_count
      t.integer :phones_count
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.references :dispatched_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.datetime :dispatched_at
      t.references :cancelled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.datetime :cancelled_at
      t.timestamps
    end
    add_index :campaigns, %i[status send_at], name: "idx_campaigns_status_send_at"
    add_index :campaigns, :created_at, name: "index_campaigns_on_created_at"
    add_check_constraint :campaigns,
                         "status::text = ANY (ARRAY['draft', 'scheduled', 'sending', 'sent', 'cancelled', 'failed']::text[])",
                         name: "ck_campaigns_status"
    add_check_constraint :campaigns,
                         "length(title::text) >= 3 AND length(title::text) <= 120 AND title::text = btrim(title::text)",
                         name: "ck_campaigns_title"
    add_check_constraint :campaigns, "length(body) >= 10 AND length(body) <= 2000", name: "ck_campaigns_body"
    add_check_constraint :campaigns, "status::text <> 'scheduled'::text OR send_at IS NOT NULL",
                         name: "ck_campaigns_send_at"
    add_check_constraint :campaigns,
                         "(status::text = 'failed'::text) = (failure_reason IS NOT NULL) AND " \
                         "(failure_reason IS NULL OR failure_reason::text = 'below_minimum'::text)",
                         name: "ck_campaigns_failure"
    add_check_constraint :campaigns,
                         "(cancelled_by_user_id IS NULL) = (cancelled_at IS NULL) AND " \
                         "(status::text = 'cancelled'::text) = (cancelled_at IS NOT NULL)",
                         name: "ck_campaigns_cancelled"

    create_table :campaign_recipients, id: :uuid do |t|
      t.references :campaign, type: :uuid, null: false, foreign_key: true, index: false
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :notice_read_at
      t.string :sms_status, null: false
      t.datetime :sms_sent_at
      t.string :sms_error, limit: 200
      t.datetime :created_at, null: false
    end
    add_index :campaign_recipients, %i[campaign_id citizen_id], unique: true, name: "idx_campaign_recipients_pair"
    add_index :campaign_recipients, %i[campaign_id sms_status], name: "idx_campaign_recipients_sms"
    add_check_constraint :campaign_recipients,
                         "sms_status::text = ANY (ARRAY['not_opted_in', 'duplicate_phone', 'pending', 'deferred', " \
                         "'sent', 'failed', 'unavailable']::text[])",
                         name: "ck_campaign_recipients_sms_status"

    create_table :citizen_contact_preferences, id: :uuid, primary_key: :citizen_id, default: nil do |t|
      t.boolean :sms_opt_in, null: false, default: false
      t.datetime :sms_opt_in_changed_at
      t.boolean :notices_muted, null: false, default: false
      t.timestamps
    end
    add_foreign_key :citizen_contact_preferences, :citizens

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    drop_table :citizen_contact_preferences
    drop_table :campaign_recipients
    drop_table :campaigns
    execute "DROP FUNCTION IF EXISTS rota_campaign_recipient_guard()"
    execute "DROP FUNCTION IF EXISTS rota_campaign_guard()"
    remove_column :city_profile, :campaigns_sms_enabled
    # Falha se já houver membership campaign_manager (memberships não se apagam).
    replace_roles_check(ROLES_BEFORE)
  end

  private

  # Mesma forma de 20260926000001: ANY (ARRAY[...]::text[]) sobrevive ao round-trip.
  def replace_roles_check(roles)
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{roles.map { |r| "'#{r}'" }.join(', ')}]::text[])",
                         name: "ck_memberships_role"
  end
end
