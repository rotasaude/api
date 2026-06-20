# Ver ADR-0016.
class CreateProtocolDefinitions < ActiveRecord::Migration[8.0]
  def change
    create_table :protocol_definitions, id: :uuid do |t|
      t.string  :name,    null: false
      t.integer :version, null: false
      t.references :municipality, type: :uuid, foreign_key: true
      t.jsonb  :definition, null: false
      t.string :status, null: false, default: "draft"
      t.datetime :activated_at
      t.datetime :retired_at
      t.timestamps
    end

    add_index :protocol_definitions, [:name, :version, :municipality_id],
              unique: true,
              name: "idx_protocol_definitions_name_version_muni"

    add_index :protocol_definitions, [:name, :municipality_id],
              unique: true,
              where: "status = 'active'",
              name: "idx_protocol_definitions_one_active_per_name_muni"

    add_check_constraint :protocol_definitions,
                         "status IN ('draft','active','retired')",
                         name: "ck_protocol_definitions_status"
  end
end
