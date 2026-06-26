# apps/api/db/migrate/20260620000030_processed_events_tenant_and_domain_events_shape.rb
# - processed_events ganha municipality_id e RLS (ADR-0020).
#   Índice único permanece (event_id, consumer) — event_id é UUID global.
# - domain_events drop aggregate_type/aggregate_id (ADR-0020 não os carrega).
class ProcessedEventsTenantAndDomainEventsShape < ActiveRecord::Migration[8.1]
  def up
    add_reference :processed_events, :municipality, type: :uuid, foreign_key: true, index: true
    execute("DELETE FROM processed_events WHERE municipality_id IS NULL;")
    change_column_null :processed_events, :municipality_id, false

    enable_rls_on(:processed_events)

    remove_index :domain_events, name: "index_domain_events_on_aggregate_type_and_aggregate_id" rescue nil
    remove_column :domain_events, :aggregate_type
    remove_column :domain_events, :aggregate_id
  end

  def down
    add_column :domain_events, :aggregate_type, :string, null: false, default: ""
    add_column :domain_events, :aggregate_id,   :string, null: false, default: ""
    add_index  :domain_events, [:aggregate_type, :aggregate_id], name: "index_domain_events_on_aggregate_type_and_aggregate_id"

    disable_rls_on(:processed_events)
    remove_reference :processed_events, :municipality, foreign_key: true
  end
end
