# Imutabilidade da auditoria de manutenção (spec §9). O mantenedor pode tudo —
# menos reescrever o registro do que fez. Nenhuma mutation toca platform_events,
# e este trigger fecha o caminho que sobra: um bug no app, ou um psql aberto com
# o papel da aplicação.
#
# Só published_at pode mudar (é o outbox, ADR-0004). O filtro é por nome
# maintenance.%: o resto de platform_events segue com a purga por retenção.
#
# ATENÇÃO: trigger não entra em db/platform_schema.rb (o dump em Ruby não o
# representa). Ele existe onde as MIGRATIONS rodaram; spec/events/
# maintenance_audit_spec.rb confere a presença no pg_trigger para que um banco
# reconstruído por schema:load falhe alto.
class MaintenanceEventsImmutable < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION platform_events_maintenance_immutable() RETURNS trigger AS $fn$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'maintenance audit events are immutable: DELETE refused (%)', OLD.name;
        END IF;

        IF NEW.name IS DISTINCT FROM OLD.name
           OR NEW.payload IS DISTINCT FROM OLD.payload
           OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
          RAISE EXCEPTION 'maintenance audit events are immutable: only published_at may change (%)', OLD.name;
        END IF;

        RETURN NEW;
      END;
      $fn$ LANGUAGE plpgsql;

      CREATE TRIGGER platform_events_maintenance_immutable
        BEFORE UPDATE OR DELETE ON platform_events
        FOR EACH ROW
        WHEN (OLD.name LIKE 'maintenance.%')
        EXECUTE FUNCTION platform_events_maintenance_immutable();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS platform_events_maintenance_immutable ON platform_events;
      DROP FUNCTION IF EXISTS platform_events_maintenance_immutable();
    SQL
  end
end
