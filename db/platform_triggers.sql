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
-- O conteúdo é o estado CORRENTE da função, igual ao da migração
-- 20260917000003 (que substituiu a de 20260917000002 para passar a olhar
-- também o `id`). Mudança futura no trigger muda ESTE arquivo, e a migração
-- que a aplica executa este arquivo — nunca duas cópias do corpo.
--
-- O que isto defende: bug de aplicação, update_all/delete_all, um psql aberto
-- com o papel da aplicação. O que NÃO defende: o dono das tabelas, que sempre
-- pode DROP TRIGGER — como já diz o cabeçalho de db/city_triggers.sql.

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

-- DROP + CREATE em vez de CREATE OR REPLACE TRIGGER: o REPLACE só existe do
-- PostgreSQL 14 para cima, e este arquivo precisa valer em qualquer banco que
-- a aplicação aceite.
DROP TRIGGER IF EXISTS platform_events_maintenance_immutable ON platform_events;

CREATE TRIGGER platform_events_maintenance_immutable
  BEFORE UPDATE OR DELETE ON platform_events
  FOR EACH ROW
  WHEN (OLD.name LIKE 'maintenance.%')
  EXECUTE FUNCTION platform_events_maintenance_immutable();
