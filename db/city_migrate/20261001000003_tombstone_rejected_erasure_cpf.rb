# ADR 0026: a recusa do pedido de exclusão também troca o cpf do pedido por um
# marcador; o trigger passa a aceitar a troca na UPDATE que recusa.
class TombstoneRejectedErasureCpf < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    # Volta à função anterior: o cpf só muda na UPDATE que confirma.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rota_citizen_erasure_request_guard() RETURNS trigger AS $fn$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'citizen_erasure_requests is append-only: DELETE refused';
        END IF;
        IF OLD.status <> 'pending' THEN
          RAISE EXCEPTION 'citizen_erasure_requests: already decided';
        END IF;
        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.presented_citizen_id IS DISTINCT FROM OLD.presented_citizen_id
           OR NEW.requested_by_user_id IS DISTINCT FROM OLD.requested_by_user_id
           OR NEW.document_checked IS DISTINCT FROM OLD.document_checked
           OR NEW.created_at IS DISTINCT FROM OLD.created_at
           OR (NEW.cpf IS DISTINCT FROM OLD.cpf AND NEW.status <> 'confirmed') THEN
          RAISE EXCEPTION 'citizen_erasure_requests: only the decision columns may change';
        END IF;
        RETURN NEW;
      END;
      $fn$ LANGUAGE plpgsql;
    SQL
  end
end
