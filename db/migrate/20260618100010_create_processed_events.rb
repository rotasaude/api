# Ver ADR-0005.
class CreateProcessedEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :processed_events, id: :uuid do |t|
      t.string   :consumer,     null: false
      t.string   :event_id,     null: false
      t.datetime :processed_at, null: false
      t.timestamps
    end

    add_index :processed_events, [:consumer, :event_id], unique: true
    add_index :processed_events, :processed_at
  end
end
