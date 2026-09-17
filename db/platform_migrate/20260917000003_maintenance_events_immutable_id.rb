# Minor (fix round 2): a condição de imutabilidade não olhava a CHAVE. Trocar o
# `id` de um evento de manutenção é reescrever a auditoria de um jeito pior do
# que editar o payload — o evento continua lá, com o conteúdo intacto, apontando
# para outro lugar na correlação de quem lê. Só a FUNÇÃO é substituída: o
# trigger de 20260917000002 continua o mesmo e passa a executar esta versão.
class MaintenanceEventsImmutableId < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION platform_events_maintenance_immutable() RETURNS trigger AS $fn$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'maintenance audit events are immutable: DELETE refused (%)', OLD.name;
        END IF;

        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.name IS DISTINCT FROM OLD.name
           OR NEW.payload IS DISTINCT FROM OLD.payload
           OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
          RAISE EXCEPTION 'maintenance audit events are immutable: only published_at may change (%)', OLD.name;
        END IF;

        RETURN NEW;
      END;
      $fn$ LANGUAGE plpgsql;
    SQL
  end

  def down
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
    SQL
  end
end
