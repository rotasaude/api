# Ver ADR-0012.
class CreateConversations < ActiveRecord::Migration[8.0]
  def change
    create_table :conversations, id: :uuid do |t|
      t.references :municipality, type: :uuid, foreign_key: true
      t.string :phone, null: false                # encrypts :phone, deterministic: true
      t.string :state, null: false, default: "greeting"
      t.timestamps
    end

    add_index :conversations, :phone, unique: true
    add_index :conversations, :state
  end
end
