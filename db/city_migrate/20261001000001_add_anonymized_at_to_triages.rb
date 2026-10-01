# ADR 0026: a revogação anonimiza também a triagem concluída sem atendimento;
# anonymized_at marca a anonimização e libera o bairro nulo no trigger.
class AddAnonymizedAtToTriages < ActiveRecord::Migration[8.1]
  def up
    add_column :triages, :anonymized_at, :timestamptz
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    # O arquivo de triggers referencia NEW.anonymized_at: reescreve a função
    # sem a coluna antes de removê-la.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rota_triage_neighborhood_guard() RETURNS trigger AS $fn$
      BEGIN
        IF NEW.neighborhood_id IS DISTINCT FROM OLD.neighborhood_id THEN
          IF NEW.neighborhood_id IS NULL AND NEW.status = 'aborted_by_revocation' THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'triages: neighborhood_id never changes after insert (only to NULL on revocation)';
        END IF;
        RETURN NEW;
      END;
      $fn$ LANGUAGE plpgsql;
    SQL
    remove_column :triages, :anonymized_at
  end
end
