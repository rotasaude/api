-- Triggers do banco de PLATAFORMA. Fonte ÚNICA, no mesmo desenho de
-- db/city_triggers.sql: o dump em Ruby (db/platform_schema.rb) não representa
-- trigger, então um banco construído a partir dele nasce SEM esta proteção.
-- Quem constrói assim é mais gente do que parece: `db:migrate` num banco vazio
-- carrega o schema e marca todas as migrações como aplicadas, sem executar
-- nenhuma — foi assim que a CI rodou a suíte pela primeira vez com o trigger
-- ausente, e é assim que uma plataforma recém-provisionada nasceria.
--
-- Por isso lib/tasks/platform.rake (platform:triggers) executa este arquivo, e
-- bin/migrate o chama depois do db:migrate. Idempotente: pode rodar quantas
-- vezes for preciso.
--
-- O conteúdo é o estado CORRENTE do trigger. Histórico: 20260917000002/3
-- protegiam só maintenance.%; 20260927300002 (F-07.11, fechamento do módulo
-- 07) estendeu a imutabilidade a toda a trilha de plataforma. Mudança futura
-- no trigger muda ESTE arquivo, e a migração que a aplica executa este
-- arquivo — nunca duas cópias do corpo.
--
-- O que isto defende: bug de aplicação, update_all/delete_all, um psql aberto
-- com o papel da aplicação. O que NÃO defende: o dono das tabelas, que sempre
-- pode DROP TRIGGER — como já diz o cabeçalho de db/city_triggers.sql.

-- Toda a trilha de plataforma é imutável (ADR-0014/0020; F-07.11): só
-- published_at pode mudar (é o outbox, ADR-0004). DELETE: auditoria de
-- manutenção nunca; o resto só além da retenção de 12 meses — o TTL de uma
-- purga futura, imposto pelo banco (mesmo desenho de domain_events em
-- db/city_triggers.sql). occurred_at é timestamp sem fuso gravado em UTC.
CREATE OR REPLACE FUNCTION platform_events_immutable() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.name LIKE 'maintenance.%' THEN
      RAISE EXCEPTION 'maintenance audit events are immutable: DELETE refused (%)', OLD.name;
    END IF;
    IF OLD.occurred_at >= (now() AT TIME ZONE 'UTC') - interval '12 months' THEN
      RAISE EXCEPTION 'platform events are immutable: DELETE refused inside retention (12 months) (%)', OLD.name;
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'platform events are immutable: only published_at may change (%)', OLD.name;
  END IF;

  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- DROP + CREATE em vez de CREATE OR REPLACE TRIGGER: o REPLACE só existe do
-- PostgreSQL 14 para cima, e este arquivo precisa valer em qualquer banco que
-- a aplicação aceite. O trigger antigo (só maintenance.%) sai junto.
DROP TRIGGER IF EXISTS platform_events_maintenance_immutable ON platform_events;
DROP FUNCTION IF EXISTS platform_events_maintenance_immutable();
DROP TRIGGER IF EXISTS platform_events_immutable ON platform_events;

CREATE TRIGGER platform_events_immutable
  BEFORE UPDATE OR DELETE ON platform_events
  FOR EACH ROW
  EXECUTE FUNCTION platform_events_immutable();

-- Fuso da cidade (api#27): definido no provisionamento e não muda (decisão do
-- usuário, api#36). Trocar o fuso deslocaria prazos, faltas e o "hoje" da
-- cidade, e os fatos diários já gravados ficariam no fuso antigo.
CREATE OR REPLACE FUNCTION cities_time_zone_immutable() RETURNS trigger AS $fn$
BEGIN
  IF NEW.time_zone IS DISTINCT FROM OLD.time_zone THEN
    RAISE EXCEPTION 'cities.time_zone is set once at provisioning: UPDATE refused (%)', OLD.slug;
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS cities_time_zone_immutable ON cities;

CREATE TRIGGER cities_time_zone_immutable
  BEFORE UPDATE ON cities
  FOR EACH ROW
  EXECUTE FUNCTION cities_time_zone_immutable();

-- Terminologias (ADR 0028; spec 2026-10-05 §4): release ativa nunca muda,
-- release com falha nunca fica ativa, nada ativo ou substituído se apaga. Só
-- status (pelas transições abaixo), activated_at (na ativação) e updated_at
-- mudam.
CREATE OR REPLACE FUNCTION terminology_release_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('active', 'superseded') THEN
      RAISE EXCEPTION 'terminology release % % is immutable: DELETE refused', OLD.kind, OLD.version;
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.kind IS DISTINCT FROM OLD.kind
     OR NEW.version IS DISTINCT FROM OLD.version OR NEW.source_sha256 IS DISTINCT FROM OLD.source_sha256
     OR NEW.imported_by IS DISTINCT FROM OLD.imported_by OR NEW.imported_at IS DISTINCT FROM OLD.imported_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR (OLD.status <> 'importing' AND NEW.activated_at IS DISTINCT FROM OLD.activated_at) THEN
    RAISE EXCEPTION 'terminology release % % is immutable: only status may change', OLD.kind, OLD.version;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'importing' AND NEW.status IN ('active', 'failed'))
       OR (OLD.status = 'active' AND NEW.status = 'superseded')) THEN
    RAISE EXCEPTION 'terminology release % %: transition % -> % refused', OLD.kind, OLD.version, OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- O arquivo inteiro roda também em bancos ainda sem estas tabelas (migrações
-- antigas que o executam, platform:triggers): o trigger só é instalado onde a
-- tabela existe.
DO $$
BEGIN
  IF to_regclass('public.terminology_releases') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS terminology_releases_guard ON terminology_releases;
    CREATE TRIGGER terminology_releases_guard
      BEFORE UPDATE OR DELETE ON terminology_releases
      FOR EACH ROW EXECUTE FUNCTION terminology_release_guard();
  END IF;
END $$;

-- Códigos: entram só numa release em importação; não mudam nem saem de
-- release ativa ou substituída.
CREATE OR REPLACE FUNCTION terminology_codes_guard() RETURNS trigger AS $fn$
DECLARE
  release_status text;
  old_release_status text;
BEGIN
  SELECT status INTO release_status FROM terminology_releases
   WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.release_id ELSE NEW.release_id END;

  IF TG_OP = 'INSERT' THEN
    IF release_status IS DISTINCT FROM 'importing' THEN
      RAISE EXCEPTION '% accepts rows only for a release being imported', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE também confere a release de ORIGEM: mover a linha (release_id) para uma
  -- release em importação a tiraria de uma ativa sem que NEW a denunciasse.
  IF TG_OP = 'UPDATE' AND OLD.release_id IS DISTINCT FROM NEW.release_id THEN
    SELECT status INTO old_release_status FROM terminology_releases WHERE id = OLD.release_id;
    IF old_release_status IN ('active', 'superseded') THEN
      RAISE EXCEPTION '% rows of an active or superseded release are immutable: moving out of it refused', TG_TABLE_NAME;
    END IF;
  END IF;

  IF release_status IN ('active', 'superseded') THEN
    RAISE EXCEPTION '% rows of an active or superseded release are immutable: % refused', TG_TABLE_NAME, TG_OP;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cid10_codes', 'ciap2_codes', 'sigtap_procedures', 'sigtap_procedure_cbos',
                           'sigtap_procedure_cids', 'sigtap_procedure_instruments'] LOOP
    CONTINUE WHEN to_regclass('public.' || t) IS NULL;
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_guard', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW ' ||
                   'EXECUTE FUNCTION terminology_codes_guard()', t || '_guard', t);
  END LOOP;
END $$;
