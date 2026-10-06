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

-- attendances (spec 2026-09-24-citizen-attendance-check-in §3; ADR 0018): só
-- acréscimo, exceto encerrar UMA vez. O check-in nunca muda.
CREATE OR REPLACE FUNCTION rota_attendance_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'attendances is append-only: DELETE refused';
  END IF;
  IF OLD.status = 'closed' THEN
    RAISE EXCEPTION 'attendances: already closed';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.triage_id IS DISTINCT FROM OLD.triage_id
     OR NEW.appointment_id IS DISTINCT FROM OLD.appointment_id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.health_unit_id IS DISTINCT FROM OLD.health_unit_id
     OR NEW.checked_in_by_user_id IS DISTINCT FROM OLD.checked_in_by_user_id
     OR NEW.checked_in_at IS DISTINCT FROM OLD.checked_in_at
     OR NEW.check_in_method IS DISTINCT FROM OLD.check_in_method
     OR NEW.exception_reason IS DISTINCT FROM OLD.exception_reason
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'attendances: the check-in columns never change';
  END IF;
  IF OLD.called_at IS NOT NULL
     AND (NEW.called_at IS DISTINCT FROM OLD.called_at OR NEW.called_by_user_id IS DISTINCT FROM OLD.called_by_user_id) THEN
    RAISE EXCEPTION 'attendances: the call never changes';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT ((OLD.status = 'waiting' AND NEW.status = 'in_care')
          OR (OLD.status = 'waiting' AND NEW.status = 'closed' AND NEW.outcome = 'left')
          OR (OLD.status = 'in_care' AND NEW.status = 'closed' AND NEW.outcome IS DISTINCT FROM 'left')) THEN
    RAISE EXCEPTION 'attendances: invalid transition % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.attendances') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS attendances_guard ON attendances';
    EXECUTE 'CREATE TRIGGER attendances_guard
      BEFORE UPDATE OR DELETE ON attendances
      FOR EACH ROW EXECUTE FUNCTION rota_attendance_guard()';

    EXECUTE 'DROP TRIGGER IF EXISTS attendances_append_only_truncate ON attendances';
    EXECUTE 'CREATE TRIGGER attendances_append_only_truncate
      BEFORE TRUNCATE ON attendances
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- attendances nasce waiting (critério de fechamento do módulo 13): sem chamada
-- nem desfecho no INSERT. O CHECK ck_attendances_closing sozinho aceitaria uma
-- linha in_care ou closed coerente; a chamada e o desfecho só chegam pelas
-- transições do rota_attendance_guard.
CREATE OR REPLACE FUNCTION rota_attendance_insert_guard() RETURNS trigger AS $fn$
BEGIN
  IF NEW.status IS DISTINCT FROM 'waiting'
     OR NEW.called_at IS NOT NULL OR NEW.called_by_user_id IS NOT NULL
     OR NEW.outcome IS NOT NULL OR NEW.closed_at IS NOT NULL OR NEW.closed_by_user_id IS NOT NULL
     OR NEW.referral_unit_id IS NOT NULL OR NEW.referral_note IS NOT NULL THEN
    RAISE EXCEPTION 'attendances: born waiting, without call or outcome';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.attendances') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS attendances_born_waiting ON attendances';
    EXECUTE 'CREATE TRIGGER attendances_born_waiting
      BEFORE INSERT ON attendances
      FOR EACH ROW EXECUTE FUNCTION rota_attendance_insert_guard()';
  END IF;
END
$do$;

-- Pedido de agendamento (ADR 0019): só acréscimo; a origem nunca muda; encerrado não muda.
-- Mover para outra unidade (api#29) encerra este como `moved` e cria outro com
-- moved_from_request_id; a ligação também nunca muda.
-- Módulo 17 (ADR 0029): a unidade de destino nula (fila "sem unidade") recebe uma unidade UMA vez; depois nunca muda.
CREATE OR REPLACE FUNCTION rota_appointment_request_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'appointment_requests is append-only: DELETE refused';
  END IF;
  IF OLD.status = 'closed' THEN
    RAISE EXCEPTION 'appointment_requests: already closed';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.origin_attendance_id IS DISTINCT FROM OLD.origin_attendance_id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.root_triage_id IS DISTINCT FROM OLD.root_triage_id
     OR NEW.origin_unit_id IS DISTINCT FROM OLD.origin_unit_id
     OR (OLD.target_unit_id IS NOT NULL AND NEW.target_unit_id IS DISTINCT FROM OLD.target_unit_id)
     OR NEW.origin_triage_id IS DISTINCT FROM OLD.origin_triage_id
     OR NEW.kind IS DISTINCT FROM OLD.kind
     OR NEW.note IS DISTINCT FROM OLD.note
     OR NEW.moved_from_request_id IS DISTINCT FROM OLD.moved_from_request_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'appointment_requests: the origin columns never change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- Horário (ADR 0019): só acréscimo e as transições previstas; o que foi marcado nunca muda.
-- `moved` (api#29): o horário foi para outra unidade, num horário novo ligado a este.
CREATE OR REPLACE FUNCTION rota_appointment_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'appointments is append-only: DELETE refused';
  END IF;
  IF OLD.status IN ('checked_in', 'cancelled_by_citizen', 'expired', 'no_show', 'moved') THEN
    RAISE EXCEPTION 'appointments: already ended';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.request_id IS DISTINCT FROM OLD.request_id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.health_unit_id IS DISTINCT FROM OLD.health_unit_id
     OR NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at
     OR NEW.scheduled_by_user_id IS DISTINCT FROM OLD.scheduled_by_user_id
     OR NEW.confirmation_deadline_at IS DISTINCT FROM OLD.confirmation_deadline_at
     OR NEW.moved_from_appointment_id IS DISTINCT FROM OLD.moved_from_appointment_id
     OR NEW.professional_id IS DISTINCT FROM OLD.professional_id
     OR NEW.appointment_type_key IS DISTINCT FROM OLD.appointment_type_key
     OR NEW.ends_at IS DISTINCT FROM OLD.ends_at
     OR NEW.shift_id IS DISTINCT FROM OLD.shift_id
     OR NEW.booking_kind IS DISTINCT FROM OLD.booking_kind
     OR NEW.fit_in_reason IS DISTINCT FROM OLD.fit_in_reason
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'appointments: the scheduled columns never change';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT ((OLD.status = 'scheduled' AND NEW.status IN ('confirmed', 'cancelled_by_citizen', 'expired', 'moved'))
          OR (OLD.status = 'confirmed' AND NEW.status IN ('checked_in', 'cancelled_by_citizen', 'no_show', 'moved'))) THEN
    RAISE EXCEPTION 'appointments: invalid transition % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.appointment_requests') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_requests_guard ON appointment_requests';
    EXECUTE 'CREATE TRIGGER appointment_requests_guard
      BEFORE UPDATE OR DELETE ON appointment_requests
      FOR EACH ROW EXECUTE FUNCTION rota_appointment_request_guard()';
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_requests_append_only_truncate ON appointment_requests';
    EXECUTE 'CREATE TRIGGER appointment_requests_append_only_truncate
      BEFORE TRUNCATE ON appointment_requests
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
  IF to_regclass('public.appointments') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS appointments_guard ON appointments';
    EXECUTE 'CREATE TRIGGER appointments_guard
      BEFORE UPDATE OR DELETE ON appointments
      FOR EACH ROW EXECUTE FUNCTION rota_appointment_guard()';
    EXECUTE 'DROP TRIGGER IF EXISTS appointments_append_only_truncate ON appointments';
    EXECUTE 'CREATE TRIGGER appointments_append_only_truncate
      BEFORE TRUNCATE ON appointments
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- report_snapshots (ADR 0010): o relatório é PROVA do que foi respondido, sob
-- a versão exata do protocolo — nunca muda depois de criado. Continua
-- permitido o que o próprio app faz: reassinar (signature, CityReports::Resign
-- na rotação de chave), expirar o link (expires_at — "corrigir" um relatório é
-- expirar o token e gerar outro; updated_at acompanha um update pelo modelo) e
-- apagar (PurgeExpiredReportsJob). TRUNCATE fica de fora de propósito: esvaziar
-- a tabela é uma purga, que DELETE já pode fazer.
CREATE OR REPLACE FUNCTION rota_report_snapshot_guard() RETURNS trigger AS $fn$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.triage_id IS DISTINCT FROM OLD.triage_id
     OR NEW.protocol_definition_id IS DISTINCT FROM OLD.protocol_definition_id
     OR NEW.outcome IS DISTINCT FROM OLD.outcome
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.token IS DISTINCT FROM OLD.token
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'report_snapshots is immutable: only signature and expires_at may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.report_snapshots') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS report_snapshots_immutable ON report_snapshots';
    EXECUTE 'CREATE TRIGGER report_snapshots_immutable
      BEFORE UPDATE ON report_snapshots
      FOR EACH ROW EXECUTE FUNCTION rota_report_snapshot_guard()';
  END IF;
END
$do$;

-- consents (ADR 0008; critério de fechamento do módulo 02): o consentimento é
-- prova do que o cidadão aceitou. Só acréscimo, exceto preencher a revogação
-- UMA vez. Versão, hash do texto, canal, data e conversa nunca mudam; uma
-- linha nunca é apagada. evidence (e updated_at) continua mudando: city:rotate_key
-- recifra a coluna com a chave nova.
CREATE OR REPLACE FUNCTION rota_consent_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'consents is append-only: DELETE refused';
  END IF;
  IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
    RAISE EXCEPTION 'consents: already revoked';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
     OR NEW.version IS DISTINCT FROM OLD.version
     OR NEW.policy_text_sha IS DISTINCT FROM OLD.policy_text_sha
     OR NEW.channel IS DISTINCT FROM OLD.channel
     OR NEW.given_at IS DISTINCT FROM OLD.given_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'consents: only revoked_at (once) and evidence may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS consents_guard ON consents;
CREATE TRIGGER consents_guard
  BEFORE UPDATE OR DELETE ON consents
  FOR EACH ROW EXECUTE FUNCTION rota_consent_guard();

DROP TRIGGER IF EXISTS consents_append_only_truncate ON consents;
CREATE TRIGGER consents_append_only_truncate
  BEFORE TRUNCATE ON consents
  FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only();

-- protocol_definitions (ADR 0009; F-03.14 e critério de fechamento do módulo
-- 03): uma versão nunca é apagada — aposentar é mudar o status — e, depois de
-- publicada, definition/name/version não mudam mais: triagem e relatório
-- apontam para ESTA linha (imutabilidade por versão). draft e in_review
-- continuam editáveis. O status só anda para frente: published/active nunca
-- voltam a draft/in_review, e retired é final. published <-> active é o
-- ciclo de ativação e reversão (Protocols::Activate / RevertActivation).
CREATE OR REPLACE FUNCTION rota_protocol_definition_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'protocol_definitions: DELETE refused (retire the version instead)';
  END IF;
  IF OLD.status IN ('draft', 'in_review') THEN
    RETURN NEW;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.definition IS DISTINCT FROM OLD.definition
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.version IS DISTINCT FROM OLD.version
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'protocol_definitions: content is frozen once published';
  END IF;
  IF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
    RAISE EXCEPTION 'protocol_definitions: retired is final';
  END IF;
  IF NEW.status IN ('draft', 'in_review') THEN
    RAISE EXCEPTION 'protocol_definitions: a published version cannot go back to %', NEW.status;
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protocol_definitions_guard ON protocol_definitions;
CREATE TRIGGER protocol_definitions_guard
  BEFORE UPDATE OR DELETE ON protocol_definitions
  FOR EACH ROW EXECUTE FUNCTION rota_protocol_definition_guard();

DROP TRIGGER IF EXISTS protocol_definitions_append_only_truncate ON protocol_definitions;
CREATE TRIGGER protocol_definitions_append_only_truncate
  BEFORE TRUNCATE ON protocol_definitions
  FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only();

-- consent_terms (ADR-0013; F-06.13): o termo é append-only. O consentimento
-- do cidadão aponta para a versão e o hash do texto — mudar ou apagar um termo
-- publicado reescreveria o que ele aceitou. Versão nova é linha nova
-- (rake city:consent_term:publish). Sem trigger de TRUNCATE, como em
-- report_snapshots: a garantia é contra UPDATE/DELETE de linha.
DO $do$
BEGIN
  IF to_regclass('public.consent_terms') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS consent_terms_append_only ON consent_terms';
    EXECUTE 'CREATE TRIGGER consent_terms_append_only
      BEFORE UPDATE OR DELETE ON consent_terms
      FOR EACH ROW EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- users e memberships (ADR-0012; fechamento do módulo 06): desativar e revogar
-- são end-dating, nunca DELETE. users continua mudando (senha, MFA,
-- deactivated_at); membership só muda para receber a revogação, UMA vez —
-- papel, usuário, quem concedeu e quando nunca mudam (updated_at acompanha o
-- update pelo modelo). Sem trigger de TRUNCATE: a garantia é contra DELETE e
-- UPDATE de linha, e a limpeza das suítes/restauração usa TRUNCATE/--clean.
CREATE OR REPLACE FUNCTION rota_membership_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'memberships is append-only: DELETE refused';
  END IF;
  IF OLD.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'memberships: already revoked';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.role IS DISTINCT FROM OLD.role
     OR NEW.granted_by_id IS DISTINCT FROM OLD.granted_by_id
     OR NEW.granted_at IS DISTINCT FROM OLD.granted_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'memberships: only revoked_at may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.memberships') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS memberships_guard ON memberships';
    EXECUTE 'CREATE TRIGGER memberships_guard
      BEFORE UPDATE OR DELETE ON memberships
      FOR EACH ROW EXECUTE FUNCTION rota_membership_guard()';
  END IF;
  IF to_regclass('public.users') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS users_no_delete ON users';
    EXECUTE 'CREATE TRIGGER users_no_delete
      BEFORE DELETE ON users
      FOR EACH ROW EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- domain_events (ADR-0014; F-07.1, fechamento do módulo 07): a trilha de
-- auditoria da cidade é só acréscimo. A única mudança aceita é marcar a
-- publicação — published_at de NULL para um valor, UMA vez (IdempotentConsumer,
-- por update_all). DELETE só passa para evento além da retenção de 12 meses:
-- é o TTL da purga (PurgeDomainEventsJob, F-07.3) imposto pelo banco, não pelo
-- job — encurtar a retenção exige migração que troque este intervalo.
-- occurred_at é timestamp sem fuso gravado em UTC; comparar com
-- now() AT TIME ZONE 'UTC' não depende do TimeZone da sessão. Sem trigger de
-- TRUNCATE, como em memberships: a limpeza das suítes/restauração usa
-- TRUNCATE/--clean.
CREATE OR REPLACE FUNCTION rota_domain_event_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.occurred_at >= (now() AT TIME ZONE 'UTC') - interval '12 months' THEN
      RAISE EXCEPTION 'domain_events is append-only: DELETE refused inside retention (12 months)';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.published_at IS NOT NULL THEN
    RAISE EXCEPTION 'domain_events: already published';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.name IS DISTINCT FROM OLD.name
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'domain_events: only published_at may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.domain_events') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS domain_events_guard ON domain_events';
    EXECUTE 'CREATE TRIGGER domain_events_guard
      BEFORE UPDATE OR DELETE ON domain_events
      FOR EACH ROW EXECUTE FUNCTION rota_domain_event_guard()';
  END IF;
END
$do$;

-- professional_links (ADR 0021; spec 2026-09-27-module-10-professionals §3.2):
-- só acréscimo, exceto encerrar UMA vez. Quem, onde, com qual CBO e desde
-- quando nunca mudam; o vínculo nunca é apagado. Sem trigger de TRUNCATE,
-- como em memberships: a limpeza das suítes/restauração usa TRUNCATE/--clean.
CREATE OR REPLACE FUNCTION rota_professional_link_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'professional_links is append-only: DELETE refused';
  END IF;
  IF OLD.ended_at IS NOT NULL THEN
    RAISE EXCEPTION 'professional_links: already ended';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.professional_id IS DISTINCT FROM OLD.professional_id
     OR NEW.health_unit_id IS DISTINCT FROM OLD.health_unit_id
     OR NEW.cbo_code IS DISTINCT FROM OLD.cbo_code
     OR NEW.started_at IS DISTINCT FROM OLD.started_at
     OR NEW.started_by_user_id IS DISTINCT FROM OLD.started_by_user_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'professional_links: only the ending columns may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- professional_shifts (§3.3): só acréscimo, exceto cancelar UMA vez. No
-- INSERT, o profissional tem de ser o do vínculo (a coluna existe só para a
-- EXCLUDE) e o vínculo tem de estar ativo — "não existe turno em vínculo
-- encerrado" fica garantido pelo banco, não só pelo comando. O INSERT trava a
-- linha do vínculo com FOR SHARE antes de checar: sob READ COMMITTED, um
-- EXISTS puro não vê um UPDATE concorrente que ainda não commitou (o
-- encerramento do vínculo) e deixaria o turno entrar por uma fresta; o FOR
-- SHARE faz o INSERT esperar esse UPDATE terminar (commit ou rollback) antes
-- de decidir.
CREATE OR REPLACE FUNCTION rota_professional_shift_guard() RETURNS trigger AS $fn$
DECLARE
  link_professional uuid;
  link_ended timestamptz;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT l.professional_id, l.ended_at INTO link_professional, link_ended
      FROM professional_links l WHERE l.id = NEW.professional_link_id FOR SHARE;
    IF NOT FOUND OR link_professional IS DISTINCT FROM NEW.professional_id THEN
      RAISE EXCEPTION 'professional_shifts: professional_id must match the link';
    END IF;
    IF link_ended IS NOT NULL THEN
      RAISE EXCEPTION 'professional_shifts: link is ended';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'professional_shifts is append-only: DELETE refused';
  END IF;
  IF OLD.cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'professional_shifts: already cancelled';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.professional_link_id IS DISTINCT FROM OLD.professional_link_id
     OR NEW.professional_id IS DISTINCT FROM OLD.professional_id
     OR NEW.starts_at IS DISTINCT FROM OLD.starts_at
     OR NEW.ends_at IS DISTINCT FROM OLD.ends_at
     OR NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'professional_shifts: only the cancellation columns may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.professional_links') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS professional_links_guard ON professional_links';
    EXECUTE 'CREATE TRIGGER professional_links_guard
      BEFORE UPDATE OR DELETE ON professional_links
      FOR EACH ROW EXECUTE FUNCTION rota_professional_link_guard()';
  END IF;
  IF to_regclass('public.professional_shifts') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS professional_shifts_guard ON professional_shifts';
    EXECUTE 'CREATE TRIGGER professional_shifts_guard
      BEFORE INSERT OR UPDATE OR DELETE ON professional_shifts
      FOR EACH ROW EXECUTE FUNCTION rota_professional_shift_guard()';
  END IF;
END
$do$;

-- triages.neighborhood_id (ADR 0023; spec 2026-09-28-module-11-territory §3.3):
-- o bairro do cidadão é COPIADO na criação da triagem (StartTriage) e nunca
-- muda depois — nem para outro bairro, nem de nulo para um bairro. É o que faz
-- o painel contar cada caso no bairro onde a pessoa morava quando ele
-- aconteceu. UMA exceção (decisão de 2026-09-28): ir para NULL quando a linha
-- fica em aborted_by_revocation — a anonimização da revogação
-- (AnonymizeRevokedTriageJob) apaga o bairro junto com o conteúdo clínico. As
-- outras colunas continuam mudando. A guarda é pela COLUNA, não pela tabela:
-- triages existe desde a primeira migração, e um replay do zero executa este
-- arquivo antes de a coluna existir.
-- ADR 0026: a exceção vale também para a triagem concluída anonimizada
-- (anonymized_at preenchido, na mesma atualização que zera o bairro).
CREATE OR REPLACE FUNCTION rota_triage_neighborhood_guard() RETURNS trigger AS $fn$
BEGIN
  IF NEW.neighborhood_id IS DISTINCT FROM OLD.neighborhood_id THEN
    IF NEW.neighborhood_id IS NULL
       AND (NEW.status = 'aborted_by_revocation' OR NEW.anonymized_at IS NOT NULL) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'triages: neighborhood_id never changes after insert (only to NULL on revocation)';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'triages' AND column_name = 'neighborhood_id') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS triages_neighborhood_immutable ON triages';
    EXECUTE 'CREATE TRIGGER triages_neighborhood_immutable
      BEFORE UPDATE ON triages
      FOR EACH ROW EXECUTE FUNCTION rota_triage_neighborhood_guard()';
  END IF;
END
$do$;

-- campaigns (ADR 0024; spec 2026-09-29-module-12-campaigns §3.1): a campanha
-- enviada é prova do que a secretaria mandou e para quem — em sent, cancelled
-- ou failed nenhuma coluna muda. Em sending, a única saída é o congelamento
-- (sent ou failed), mudando só as colunas dele (status, sms_enabled,
-- recipients_count, phones_count, dispatched_at, failure_reason, updated_at).
-- draft e scheduled seguem pelos comandos. Só draft se apaga (não há rota;
-- defesa contra acidente). Sem trigger de TRUNCATE, como em memberships.
CREATE OR REPLACE FUNCTION rota_campaign_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'draft' THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'campaigns: only a draft may be deleted';
  END IF;
  IF OLD.status IN ('sent', 'cancelled', 'failed') THEN
    RAISE EXCEPTION 'campaigns: frozen after send (status %)', OLD.status;
  END IF;
  IF OLD.status = 'sending' THEN
    IF NEW.status NOT IN ('sent', 'failed') THEN
      RAISE EXCEPTION 'campaigns: sending only moves to sent or failed';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.title IS DISTINCT FROM OLD.title
       OR NEW.body IS DISTINCT FROM OLD.body
       OR NEW.audience IS DISTINCT FROM OLD.audience
       OR NEW.send_at IS DISTINCT FROM OLD.send_at
       OR NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id
       OR NEW.dispatched_by_user_id IS DISTINCT FROM OLD.dispatched_by_user_id
       OR NEW.cancelled_by_user_id IS DISTINCT FROM OLD.cancelled_by_user_id
       OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'campaigns: while sending only the freeze columns change';
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- campaign_recipients (§3.2): o público congelado. Só mudam a leitura do
-- aviso (de NULL para um valor, UMA vez) e as colunas do SMS. DELETE passa: a
-- revogação que anonimiza o cidadão apaga as linhas dele (§5.6).
CREATE OR REPLACE FUNCTION rota_campaign_recipient_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.campaign_id IS DISTINCT FROM OLD.campaign_id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'campaign_recipients: only the reading and the SMS columns change';
  END IF;
  IF OLD.notice_read_at IS NOT NULL AND NEW.notice_read_at IS DISTINCT FROM OLD.notice_read_at THEN
    RAISE EXCEPTION 'campaign_recipients: notice_read_at is set once';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.campaigns') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS campaigns_frozen_after_send ON campaigns';
    EXECUTE 'CREATE TRIGGER campaigns_frozen_after_send
      BEFORE UPDATE OR DELETE ON campaigns
      FOR EACH ROW EXECUTE FUNCTION rota_campaign_guard()';
  END IF;
  IF to_regclass('public.campaign_recipients') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS campaign_recipients_append_only ON campaign_recipients';
    EXECUTE 'CREATE TRIGGER campaign_recipients_append_only
      BEFORE UPDATE OR DELETE ON campaign_recipients
      FOR EACH ROW EXECUTE FUNCTION rota_campaign_recipient_guard()';
  END IF;
END
$do$;

-- citizen_erasure_requests (ADR 0026): só acréscimo; a decisão sai de pending
-- UMA vez; o cpf só muda na mesma UPDATE que decide por confirmar ou recusar
-- (vira o marcador; a recusa também não guarda o CPF).
CREATE OR REPLACE FUNCTION rota_citizen_erasure_request_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'citizen_erasure_requests is append-only: DELETE refused';
  END IF;
  IF OLD.status <> 'pending' THEN
    -- Linha decidida: só o cpf (e updated_at) pode mudar, para a re-cifra
    -- (CityRekey, ReencryptionJob) conseguir regravar a coluna cifrada.
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.status IS DISTINCT FROM OLD.status
       OR NEW.decided_by_user_id IS DISTINCT FROM OLD.decided_by_user_id
       OR NEW.decided_at IS DISTINCT FROM OLD.decided_at
       OR NEW.reject_reason IS DISTINCT FROM OLD.reject_reason
       OR NEW.presented_citizen_id IS DISTINCT FROM OLD.presented_citizen_id
       OR NEW.requested_by_user_id IS DISTINCT FROM OLD.requested_by_user_id
       OR NEW.document_checked IS DISTINCT FROM OLD.document_checked
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'citizen_erasure_requests: already decided';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.presented_citizen_id IS DISTINCT FROM OLD.presented_citizen_id
     OR NEW.requested_by_user_id IS DISTINCT FROM OLD.requested_by_user_id
     OR NEW.document_checked IS DISTINCT FROM OLD.document_checked
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR (NEW.cpf IS DISTINCT FROM OLD.cpf AND NEW.status NOT IN ('confirmed', 'rejected')) THEN
    RAISE EXCEPTION 'citizen_erasure_requests: only the decision columns may change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.citizen_erasure_requests') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS citizen_erasure_requests_guard ON citizen_erasure_requests';
    EXECUTE 'CREATE TRIGGER citizen_erasure_requests_guard
      BEFORE UPDATE OR DELETE ON citizen_erasure_requests
      FOR EACH ROW EXECUTE FUNCTION rota_citizen_erasure_request_guard()';
    EXECUTE 'DROP TRIGGER IF EXISTS citizen_erasure_requests_append_only_truncate ON citizen_erasure_requests';
    EXECUTE 'CREATE TRIGGER citizen_erasure_requests_append_only_truncate
      BEFORE TRUNCATE ON citizen_erasure_requests
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- appointment_reminders (api#39; ADR 0019, Revisão 2026-10-02): o lembrete de
-- confirmação é prova de que foi tentado e com que resultado. Só acréscimo;
-- um por horário (índice único).
DO $do$
BEGIN
  IF to_regclass('public.appointment_reminders') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_reminders_append_only ON appointment_reminders';
    EXECUTE 'CREATE TRIGGER appointment_reminders_append_only
      BEFORE UPDATE OR DELETE ON appointment_reminders
      FOR EACH ROW EXECUTE FUNCTION rota_append_only()';
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_reminders_append_only_truncate ON appointment_reminders';
    EXECUTE 'CREATE TRIGGER appointment_reminders_append_only_truncate
      BEFORE TRUNCATE ON appointment_reminders
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- health_unit_drains (api#29; F-09.3): o esvaziamento de unidade é prova de
-- quem moveu, para onde e por quê. Só acréscimo; o motivo nunca muda.
DO $do$
BEGIN
  IF to_regclass('public.health_unit_drains') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS health_unit_drains_append_only ON health_unit_drains';
    EXECUTE 'CREATE TRIGGER health_unit_drains_append_only
      BEFORE UPDATE OR DELETE ON health_unit_drains
      FOR EACH ROW EXECUTE FUNCTION rota_append_only()';
    EXECUTE 'DROP TRIGGER IF EXISTS health_unit_drains_append_only_truncate ON health_unit_drains';
    EXECUTE 'CREATE TRIGGER health_unit_drains_append_only_truncate
      BEFORE TRUNCATE ON health_unit_drains
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
END
$do$;

-- triage_suggestions (ADR 0027; spec 2026-10-05 §3.3): a sugestão nasce
-- pending e só sai dali uma vez, para taken (a triagem iniciada a partir dela)
-- ou expired (o protocolo deixou de estar em oferta para o par). Resolvida,
-- congela. As colunas de identidade nunca mudam. DELETE passa de propósito: a
-- exclusão do cadastro e a revogação apagam as sugestões (ADR 0026, §5.5).
CREATE OR REPLACE FUNCTION rota_triage_suggestion_guard() RETURNS trigger AS $fn$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.source_triage_id IS DISTINCT FROM OLD.source_triage_id
     OR NEW.protocol_name IS DISTINCT FROM OLD.protocol_name
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'triage_suggestions: only the status columns change';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status <> 'pending' OR NEW.status NOT IN ('taken', 'expired') THEN
      RAISE EXCEPTION 'triage_suggestions: % -> % refused (only pending -> taken | expired)', OLD.status, NEW.status;
    END IF;
  ELSIF OLD.status <> 'pending'
        AND (NEW.taken_triage_id IS DISTINCT FROM OLD.taken_triage_id
             OR NEW.resolved_at IS DISTINCT FROM OLD.resolved_at) THEN
    RAISE EXCEPTION 'triage_suggestions: a resolved suggestion is frozen';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.triage_suggestions') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS triage_suggestions_transition ON triage_suggestions';
    EXECUTE 'CREATE TRIGGER triage_suggestions_transition
      BEFORE UPDATE ON triage_suggestions
      FOR EACH ROW EXECUTE FUNCTION rota_triage_suggestion_guard()';
  END IF;
END
$do$;

-- ledi_outbox (ADR 0028; spec 2026-10-05-module-16 §6.3): a ficha aceita é prova
-- do que foi entregue ao PEC — não muda nem some, e o conteúdo dela já foi
-- apagado (CHECK ck_ledi_outbox_accepted_payload). A identidade da ficha nunca
-- muda; o uuid só muda no reenvio de uma recusada (rejected → pending); o
-- payload pode ir a nulo, nunca voltar. A re-cifra (ReencryptionJob) regrava o
-- payload não nulo de linhas não aceitas, o que continua permitido.
CREATE OR REPLACE FUNCTION rota_ledi_outbox_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'accepted' THEN
      RAISE EXCEPTION 'ledi_outbox: accepted is immutable';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'accepted' THEN
    RAISE EXCEPTION 'ledi_outbox: accepted is immutable';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.ficha_type IS DISTINCT FROM OLD.ficha_type
     OR NEW.competence IS DISTINCT FROM OLD.competence
     OR NEW.source_type IS DISTINCT FROM OLD.source_type
     OR NEW.source_id IS DISTINCT FROM OLD.source_id
     OR NEW.ledi_version IS DISTINCT FROM OLD.ledi_version
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'ledi_outbox: identity columns never change';
  END IF;
  IF NEW.uuid IS DISTINCT FROM OLD.uuid AND NOT (OLD.status = 'rejected' AND NEW.status = 'pending') THEN
    RAISE EXCEPTION 'ledi_outbox: uuid changes only when a rejected ficha is resent';
  END IF;
  IF OLD.payload IS NULL AND NEW.payload IS NOT NULL THEN
    RAISE EXCEPTION 'ledi_outbox: payload only goes to null';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- appointment_types (ADR 0029; spec 2026-10-05 §3.1): o tipo da plataforma e o
-- da cidade nunca mudam de key nem de origem; desativar em vez de apagar
-- (pedidos e horários guardam a key). Sem trigger de TRUNCATE (limpeza de suíte).
CREATE OR REPLACE FUNCTION rota_appointment_type_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'appointment_types: DELETE refused (deactivate instead)';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.key IS DISTINCT FROM OLD.key OR NEW.origin IS DISTINCT FROM OLD.origin THEN
    RAISE EXCEPTION 'appointment_types: key and origin never change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- appointment_notices (ADR 0029 §6): o aviso de lembrete só registra a
-- primeira leitura; DELETE passa de propósito (exclusão do cadastro, ADR 0026).
CREATE OR REPLACE FUNCTION rota_appointment_notice_guard() RETURNS trigger AS $fn$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.appointment_id IS DISTINCT FROM OLD.appointment_id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR (OLD.read_at IS NOT NULL AND NEW.read_at IS DISTINCT FROM OLD.read_at) THEN
    RAISE EXCEPTION 'appointment_notices: only the first read is recorded';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

DO $do$
BEGIN
  IF to_regclass('public.ledi_outbox') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS ledi_outbox_guard ON ledi_outbox';
    EXECUTE 'CREATE TRIGGER ledi_outbox_guard
      BEFORE UPDATE OR DELETE ON ledi_outbox
      FOR EACH ROW EXECUTE FUNCTION rota_ledi_outbox_guard()';
  END IF;
  IF to_regclass('public.appointment_types') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_types_guard ON appointment_types';
    EXECUTE 'CREATE TRIGGER appointment_types_guard
      BEFORE UPDATE OR DELETE ON appointment_types
      FOR EACH ROW EXECUTE FUNCTION rota_appointment_type_guard()';
  END IF;
  -- Modelo: desativar em vez de apagar (turnos apontam para ele).
  IF to_regclass('public.schedule_templates') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS schedule_templates_no_delete ON schedule_templates';
    EXECUTE 'CREATE TRIGGER schedule_templates_no_delete
      BEFORE DELETE ON schedule_templates
      FOR EACH ROW EXECUTE FUNCTION rota_append_only()';
  END IF;
  -- Ligação pedido↔triagem (fusão de triagens num pedido): só acréscimo.
  IF to_regclass('public.appointment_request_triages') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_request_triages_append_only ON appointment_request_triages';
    EXECUTE 'CREATE TRIGGER appointment_request_triages_append_only
      BEFORE UPDATE OR DELETE ON appointment_request_triages
      FOR EACH ROW EXECUTE FUNCTION rota_append_only()';
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_request_triages_append_only_truncate ON appointment_request_triages';
    EXECUTE 'CREATE TRIGGER appointment_request_triages_append_only_truncate
      BEFORE TRUNCATE ON appointment_request_triages
      FOR EACH STATEMENT EXECUTE FUNCTION rota_append_only()';
  END IF;
  IF to_regclass('public.appointment_notices') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS appointment_notices_guard ON appointment_notices';
    EXECUTE 'CREATE TRIGGER appointment_notices_guard
      BEFORE UPDATE ON appointment_notices
      FOR EACH ROW EXECUTE FUNCTION rota_appointment_notice_guard()';
  END IF;
END
$do$;
