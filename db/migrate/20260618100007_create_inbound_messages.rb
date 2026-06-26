# Ver ADR-0010 e ADR-0011.
class CreateInboundMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :inbound_messages, id: :uuid do |t|
      t.string :message_id, null: false   # id da Meta
      t.string :from,       null: false
      t.string :kind,       null: false   # text, button, interactive...
      t.text   :raw,        null: false   # encrypts :raw
      t.timestamps
    end

    add_index :inbound_messages, :message_id, unique: true
    add_index :inbound_messages, :from
    add_index :inbound_messages, :created_at
  end
end
