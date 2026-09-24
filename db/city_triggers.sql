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

-- citizen_verifications (spec 2026-09-24-citizen-presencial-verification §3):
-- só acréscimo, exceto preencher a revogação UMA vez. Quem validou, quando e
-- para qual cidadão nunca mudam; uma linha nunca é apagada.
--
-- to_regclass guarda os dois DROP/CREATE TRIGGER: este arquivo único é
-- executado tanto pela migração que criou citizen_verifications (mais nova)
-- quanto pela migração mais antiga que criou protocol_signatures (achado ao
-- rodar a suíte: um replay do zero passa por ELA primeiro, antes da tabela
-- citizen_verifications existir — sem a guarda, "relation does not exist").
-- A própria função não referencia a tabela, então não precisa de guarda.
CREATE OR REPLACE FUNCTION rota_citizen_verification_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'citizen_verifications is append-only: DELETE refused';
  END IF;
  IF OLD.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'citizen_verifications: already revoked';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.verified_by_user_id IS DISTINCT FROM OLD.verified_by_user_id
     OR NEW.verified_at IS DISTINCT FROM OLD.verified_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'citizen_verifications: only the revocation columns may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.citizen_verifications') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS citizen_verifications_guard ON citizen_verifications';
    EXECUTE 'CREATE TRIGGER citizen_verifications_guard
      BEFORE UPDATE OR DELETE ON citizen_verifications
      FOR EACH ROW EXECUTE FUNCTION rota_citizen_verification_guard()';

    EXECUTE 'DROP TRIGGER IF EXISTS citizen_verifications_append_only_truncate ON citizen_verifications';
    EXECUTE 'CREATE TRIGGER citizen_verifications_append_only_truncate
      BEFORE TRUNCATE ON citizen_verifications
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;
