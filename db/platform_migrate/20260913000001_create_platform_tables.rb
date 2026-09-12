# Tabelas de plataforma lidas ANTES de saber a cidade: roteamento de canal
# WhatsApp, canais desconhecidos, contas de operador e auditoria platform-scope
# (ADR do banco-por-cidade). Colunas e índices espelham municipality_channels,
# unknown_channels, users, sessions e domain_events do banco compartilhado
# (db/structure.sql) — ver task-3-context.md.
class CreatePlatformTables < ActiveRecord::Migration[8.1]
  def change
    create_table :city_channels, id: :uuid do |t|
      t.uuid    :city_id,              null: false
      t.string  :phone_number_id,      null: false
      t.string  :waba_id,              null: false
      t.string  :display_phone_number, null: false
      t.text    :access_token,         null: false
      t.boolean :active,               null: false, default: true
      t.timestamps
    end
    add_index :city_channels, :city_id
    add_index :city_channels, [:city_id, :active]
    add_index :city_channels, :phone_number_id, unique: true
    add_foreign_key :city_channels, :cities

    create_table :unknown_channels, id: :uuid do |t|
      t.string   :phone_number_id, null: false
      t.integer  :hits,            null: false, default: 1
      t.jsonb    :sample_change,   null: false, default: {}
      t.datetime :first_seen_at,   null: false
      t.datetime :last_seen_at,    null: false
      t.timestamps
    end
    add_index :unknown_channels, :phone_number_id, unique: true

    create_table :operators, id: :uuid do |t|
      t.string   :email_address,      null: false
      t.string   :password_digest,    null: false
      t.datetime :deactivated_at
      t.boolean  :otp_enabled,        null: false, default: false
      t.string   :otp_secret
      t.jsonb    :otp_recovery_codes, null: false, default: []
      t.timestamps
    end
    add_index :operators, "lower(email_address)", unique: true, name: "index_operators_on_lower_email"

    create_table :operator_sessions, id: :uuid do |t|
      t.uuid     :operator_id, null: false
      t.string   :ip_address
      t.string   :user_agent
      t.datetime :mfa_verified_at
      t.timestamps
    end
    add_index :operator_sessions, :operator_id
    add_foreign_key :operator_sessions, :operators

    create_table :platform_events, id: :uuid do |t|
      t.string   :name,         null: false
      t.datetime :occurred_at,  null: false
      t.jsonb    :payload,      null: false, default: {}
      t.datetime :published_at
      t.timestamps
    end
    add_index :platform_events, :name
    add_index :platform_events, :occurred_at
    add_index :platform_events, :occurred_at, where: "published_at IS NULL", name: "idx_platform_events_pending"
  end
end
