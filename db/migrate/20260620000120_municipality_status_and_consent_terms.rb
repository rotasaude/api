# Status para suspensão futura (ADR-0024). consent_terms e alert_recipients
# como data plane (RLS).
class MunicipalityStatusAndConsentTerms < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:municipalities, :status)
      add_column :municipalities, :status, :string, null: false, default: "active"
      add_check_constraint :municipalities, "status IN ('active','suspended')", name: "ck_municipality_status"
    end

    create_table :consent_terms, id: :uuid do |t|
      t.references :municipality, type: :uuid, foreign_key: true, null: false, index: true
      t.string  :version,     null: false
      t.text    :body,        null: false
      t.datetime :published_at, null: false
      t.timestamps
      t.index [:municipality_id, :version], unique: true
    end
    enable_rls_on(:consent_terms)
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON consent_terms TO rota_app, rota_saude;")

    create_table :alert_recipients, id: :uuid do |t|
      t.references :municipality, type: :uuid, foreign_key: true, null: false, index: true
      t.string  :channel,         null: false
      t.string  :destination,     null: false
      t.integer :escalation_order, null: false, default: 0
      t.boolean :active,          null: false, default: true
      t.timestamps
      t.index [:municipality_id, :escalation_order]
    end
    add_check_constraint :alert_recipients, "channel IN ('whatsapp','email')", name: "ck_alert_recipients_channel"
    enable_rls_on(:alert_recipients)
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON alert_recipients TO rota_app, rota_saude;")
  end

  def down
    disable_rls_on(:alert_recipients)
    drop_table :alert_recipients
    disable_rls_on(:consent_terms)
    drop_table :consent_terms
    remove_column :municipalities, :status if column_exists?(:municipalities, :status)
  end
end
