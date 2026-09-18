-- Triggers do banco de CIDADE. Fonte ÚNICA: executado pela migração que os
-- criou E por lib/tasks/city.rake (load_city_schema), depois de carregar
-- db/city_schema.rb — o dump em Ruby não representa trigger, e sem isto os
-- bancos carregados do dump (testes, dev) ficariam sem a proteção.
-- Idempotente: pode rodar quantas vezes for preciso.

CREATE OR REPLACE FUNCTION rota_append_only() RETURNS trigger AS $fn$
BEGIN
  RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP;
END;
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protocol_contributions_append_only ON protocol_contributions;
CREATE TRIGGER protocol_contributions_append_only
  BEFORE UPDATE OR DELETE ON protocol_contributions
  FOR EACH ROW EXECUTE FUNCTION rota_append_only();

DROP TRIGGER IF EXISTS protocol_signatures_append_only ON protocol_signatures;
CREATE TRIGGER protocol_signatures_append_only
  BEFORE UPDATE OR DELETE ON protocol_signatures
  FOR EACH ROW EXECUTE FUNCTION rota_append_only();

DROP TRIGGER IF EXISTS protocol_activations_append_only ON protocol_activations;
CREATE TRIGGER protocol_activations_append_only
  BEFORE UPDATE OR DELETE ON protocol_activations
  FOR EACH ROW EXECUTE FUNCTION rota_append_only();
