# Parking para webhooks com phone_number_id desconhecido (ADR-0021).
# Operador é alertado via Platform.audit.
class CreateUnknownChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :unknown_channels, id: :uuid do |t|
      t.string :phone_number_id, null: false
      t.jsonb  :sample_change,   null: false, default: {}
      t.integer :hits, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      t.timestamps
      t.index :phone_number_id, unique: true
    end

    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON unknown_channels TO rota_app, rota_saude;")
  end
end
