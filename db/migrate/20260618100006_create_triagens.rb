# Ver ADR-0006 e ADR-0013.
class CreateTriagens < ActiveRecord::Migration[8.0]
  def change
    create_table :triagens, id: :uuid do |t|
      t.references :conversation,         type: :uuid, null: false, foreign_key: true
      t.references :protocol_definition,  type: :uuid, null: false, foreign_key: true
      t.string   :protocol_name, null: false
      t.string   :current_step
      t.jsonb    :answers, null: false, default: {}
      t.jsonb    :outcome
      t.string   :tier
      t.integer  :priority
      t.string   :status, null: false, default: "in_progress"
      t.datetime :completed_at
      t.timestamps
    end

    add_index :triagens, [:conversation_id, :status]
    add_index :triagens, :status
    add_index :triagens, :tier
    add_index :triagens, [:conversation_id, :created_at]

    # Garante no máximo uma triagem em curso por conversa.
    add_index :triagens, :conversation_id,
              unique: true,
              where: "status = 'in_progress'",
              name: "idx_triagens_one_in_progress_per_conversation"

    add_check_constraint :triagens,
                         "status IN ('in_progress','completed','aborted_by_revocation')",
                         name: "ck_triagens_status"
  end
end
