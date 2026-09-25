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

-- Pedido de agendamento (ADR 0019): só acréscimo; a origem nunca muda; encerrado não muda.
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
     OR NEW.target_unit_id IS DISTINCT FROM OLD.target_unit_id
     OR NEW.kind IS DISTINCT FROM OLD.kind
     OR NEW.note IS DISTINCT FROM OLD.note
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'appointment_requests: the origin columns never change';
  END IF;
  RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- Horário (ADR 0019): só acréscimo e as transições previstas; o que foi marcado nunca muda.
CREATE OR REPLACE FUNCTION rota_appointment_guard() RETURNS trigger AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'appointments is append-only: DELETE refused';
  END IF;
  IF OLD.status IN ('checked_in', 'cancelled_by_citizen', 'expired', 'no_show') THEN
    RAISE EXCEPTION 'appointments: already ended';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.request_id IS DISTINCT FROM OLD.request_id
     OR NEW.citizen_id IS DISTINCT FROM OLD.citizen_id
     OR NEW.health_unit_id IS DISTINCT FROM OLD.health_unit_id
     OR NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at
     OR NEW.scheduled_by_user_id IS DISTINCT FROM OLD.scheduled_by_user_id
     OR NEW.confirmation_deadline_at IS DISTINCT FROM OLD.confirmation_deadline_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'appointments: the scheduled columns never change';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT ((OLD.status = 'scheduled' AND NEW.status IN ('confirmed', 'cancelled_by_citizen', 'expired'))
          OR (OLD.status = 'confirmed' AND NEW.status IN ('checked_in', 'cancelled_by_citizen', 'no_show'))) THEN
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
