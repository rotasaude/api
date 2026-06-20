# apps/api/db/migrate/20260620000010_add_municipality_id_to_data_plane.rb
# Adiciona municipality_id às tabelas de data plane que ainda não têm
# (ADR-0019). Backfill de dados existentes via conversation.municipality_id
# quando aplicável. NOT NULL após backfill.
class AddMunicipalityIdToDataPlane < ActiveRecord::Migration[8.1]
  def up
    add_reference :triagens,          :municipality, type: :uuid, foreign_key: true, index: true
    add_reference :consents,          :municipality, type: :uuid, foreign_key: true, index: true
    add_reference :inbound_messages,  :municipality, type: :uuid, foreign_key: true, index: true
    add_reference :outbound_messages, :municipality, type: :uuid, foreign_key: true, index: true
    add_reference :report_snapshots,  :municipality, type: :uuid, foreign_key: true, index: true
    add_reference :domain_events,     :municipality, type: :uuid, foreign_key: true, index: true

    # Backfill: para tabelas filhas de conversation, copiar do pai.
    execute(<<~SQL.squish)
      UPDATE triagens t
         SET municipality_id = c.municipality_id
        FROM conversations c
       WHERE t.conversation_id = c.id
         AND t.municipality_id IS NULL;
    SQL
    execute(<<~SQL.squish)
      UPDATE consents co
         SET municipality_id = c.municipality_id
        FROM conversations c
       WHERE co.conversation_id = c.id
         AND co.municipality_id IS NULL;
    SQL
    execute(<<~SQL.squish)
      UPDATE report_snapshots rs
         SET municipality_id = t.municipality_id
        FROM triagens t
       WHERE rs.triagem_id = t.id
         AND rs.municipality_id IS NULL;
    SQL
    # inbound_messages, outbound_messages, domain_events sem origem certa:
    # se houver linha sem tenant, é dado de teste pré-multi-tenant. Apagar.
    execute("DELETE FROM inbound_messages  WHERE municipality_id IS NULL;")
    execute("DELETE FROM outbound_messages WHERE municipality_id IS NULL;")
    execute("DELETE FROM domain_events     WHERE municipality_id IS NULL;")

    change_column_null :triagens,          :municipality_id, false
    change_column_null :consents,          :municipality_id, false
    change_column_null :inbound_messages,  :municipality_id, false
    change_column_null :outbound_messages, :municipality_id, false
    change_column_null :report_snapshots,  :municipality_id, false
    # domain_events FICA NOT NULL aqui; vira nullable no Phase 4 (emenda 0023).
    change_column_null :domain_events,     :municipality_id, false
  end

  def down
    remove_reference :triagens,          :municipality, foreign_key: true
    remove_reference :consents,          :municipality, foreign_key: true
    remove_reference :inbound_messages,  :municipality, foreign_key: true
    remove_reference :outbound_messages, :municipality, foreign_key: true
    remove_reference :report_snapshots,  :municipality, foreign_key: true
    remove_reference :domain_events,     :municipality, foreign_key: true
  end
end
