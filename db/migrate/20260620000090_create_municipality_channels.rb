# Roteamento phone_number_id → municipality_id (ADR-0021).
# Control plane: RLS-exempt. access_token via Active Record Encryption.
class CreateMunicipalityChannels < ActiveRecord::Migration[8.1]
  def up
    create_table :municipality_channels, id: :uuid do |t|
      t.references :municipality,       type: :uuid, foreign_key: true, null: false, index: true
      t.string     :phone_number_id,    null: false
      t.string     :waba_id,            null: false
      t.string     :display_phone_number, null: false
      t.text       :access_token,       null: false   # encrypts on model
      t.boolean    :active,             null: false, default: true
      t.timestamps
      t.index :phone_number_id, unique: true
      t.index [:municipality_id, :active]
    end

    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON municipality_channels TO rota_app, rota_saude;")
  end

  def down
    drop_table :municipality_channels
  end
end
