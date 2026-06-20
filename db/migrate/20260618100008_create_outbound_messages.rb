# Ver ADR-0014.
class CreateOutboundMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :outbound_messages, id: :uuid do |t|
      t.string  :to,              null: false
      t.jsonb   :template,        null: false
      t.string  :idempotency_key, null: false
      t.integer :status,          null: false   # HTTP status code da Cloud API
      t.text    :response
      t.jsonb   :context, null: false, default: {}
      t.timestamps
    end

    add_index :outbound_messages, :idempotency_key, unique: true
    add_index :outbound_messages, :to
    add_index :outbound_messages, [:status, :created_at]
  end
end
