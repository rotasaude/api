# Ver ADR-0007.
class CreateReportSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :report_snapshots, id: :uuid do |t|
      t.references :triagem,             type: :uuid, null: false, foreign_key: true
      t.references :protocol_definition, type: :uuid, null: false, foreign_key: true
      t.jsonb    :outcome,    null: false
      t.jsonb    :payload,    null: false
      t.string   :token,      null: false
      t.string   :signature,  null: false
      t.datetime :expires_at
      t.timestamps
    end

    add_index :report_snapshots, :token, unique: true
    add_index :report_snapshots, :triagem_id, unique: true,
              name: "idx_report_snapshots_one_per_triagem"
    add_index :report_snapshots, :expires_at
  end
end
