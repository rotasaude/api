-- Triggers do banco de CIDADE. Fonte ÚNICA: executado pela migração que os
-- criou E por lib/tasks/city.rake (load_city_schema), depois de carregar
-- db/city_schema.rb — o dump em Ruby não representa trigger, e sem isto os
-- bancos carregados do dump (testes, dev) ficariam sem a proteção.
-- Idempotente: pode rodar quantas vezes for preciso.
--
-- O que isto defende: bug de aplicação, update_all/delete_all, TRUNCATE
-- acidental, um psql aberto com o papel de runtime da cidade — qualquer
-- caminho que fale SQL sem passar pelo modelo. O que isto NÃO defende: o
-- DONO das tabelas. O papel de runtime da cidade é o dono (owner) de
-- protocol_contributions/protocol_signatures/protocol_activations, e o dono
-- de uma tabela sempre pode DROP TRIGGER ou ALTER TABLE ... DISABLE TRIGGER
-- nela — nenhum trigger BEFORE impede isso. A garantia aqui é contra erro e
-- acidente, não contra um adversário com a credencial de dono.

CREATE OR REPLACE FUNCTION rota_append_only() RETURNS trigger AS $fn$
BEGIN
  RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP;
END;
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protocol_contributions_append_only ON protocol_contributions;
CREATE TRIGGER protocol_contributions_append_only
  BEFORE UPDATE OR DELETE ON protocol_contributions
  FOR EACH ROW EXECUTE FUNCTION rota_append_only();

-- TRUNCATE não dispara trigger de linha (não há OLD/NEW por linha para uma
-- operação que esvazia a tabela inteira de uma vez) — só um trigger de
-- ESTATUTO (FOR EACH STATEMENT) o vê. rota_append_only não referencia
-- OLD/NEW, então a mesma função serve os dois níveis.
DROP TRIGGER IF EXISTS protocol_contributions_append_only_truncate ON protocol_contributions;
CREATE TRIGGER protocol_contributions_append_only_truncate
  BEFORE TRUNCATE ON protocol_contributions
  FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only();

DROP TRIGGER IF EXISTS protocol_signatures_append_only ON protocol_signatures;
CREATE TRIGGER protocol_signatures_append_only
  BEFORE UPDATE OR DELETE ON protocol_signatures
  FOR EACH ROW EXECUTE FUNCTION rota_append_only();

DROP TRIGGER IF EXISTS protocol_signatures_append_only_truncate ON protocol_signatures;
CREATE TRIGGER protocol_signatures_append_only_truncate
  BEFORE TRUNCATE ON protocol_signatures
  FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only();

DROP TRIGGER IF EXISTS protocol_activations_append_only ON protocol_activations;
CREATE TRIGGER protocol_activations_append_only
  BEFORE UPDATE OR DELETE ON protocol_activations
  FOR EACH ROW EXECUTE FUNCTION rota_append_only();

DROP TRIGGER IF EXISTS protocol_activations_append_only_truncate ON protocol_activations;
CREATE TRIGGER protocol_activations_append_only_truncate
  BEFORE TRUNCATE ON protocol_activations
  FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only();
