# Ver ADR-0003 e ADR-0009.
class CreateDomainEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :domain_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string   :name,           null: false
      t.string   :aggregate_type, null: false
      t.string   :aggregate_id,   null: false
      t.jsonb    :payload,        null: false, default: {}
      t.datetime :occurred_at,    null: false
      t.datetime :published_at
      t.timestamps
    end

    add_index :domain_events, :name
    add_index :domain_events, [:aggregate_type, :aggregate_id]
    add_index :domain_events, :occurred_at
    add_index :domain_events, :occurred_at,
              where: "published_at IS NULL",
              name: "idx_domain_events_pending"
  end
end
