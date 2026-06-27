--
-- PostgreSQL database dump
--

\restrict LQXWUQuhdQui11odJCkYWFtLWahaIdJMlOpGcpffEZjukCOKZmWKEltbTsiKUkN

-- Dumped from database version 15.13 (Homebrew)
-- Dumped by pg_dump version 15.18 (Debian 15.18-0+deb12u1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alert_recipients; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.alert_recipients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    active boolean DEFAULT true NOT NULL,
    channel character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    destination character varying NOT NULL,
    escalation_order integer DEFAULT 0 NOT NULL,
    municipality_id uuid NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ck_alert_recipients_channel CHECK (((channel)::text = ANY (ARRAY[('whatsapp'::character varying)::text, ('email'::character varying)::text])))
);


ALTER TABLE public.alert_recipients OWNER TO rota_app;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.ar_internal_metadata OWNER TO rota_app;

--
-- Name: authors; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.authors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    email character varying NOT NULL,
    municipality_id uuid,
    name character varying,
    token character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.authors OWNER TO rota_app;

--
-- Name: consent_terms; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.consent_terms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    body text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    municipality_id uuid NOT NULL,
    published_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    version character varying NOT NULL
);


ALTER TABLE public.consent_terms OWNER TO rota_app;

--
-- Name: consents; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.consents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel character varying NOT NULL,
    conversation_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    evidence text,
    given_at timestamp(6) without time zone NOT NULL,
    municipality_id uuid NOT NULL,
    policy_text_sha character varying NOT NULL,
    revoked_at timestamp(6) without time zone,
    updated_at timestamp(6) without time zone NOT NULL,
    version integer NOT NULL
);

ALTER TABLE ONLY public.consents FORCE ROW LEVEL SECURITY;


ALTER TABLE public.consents OWNER TO rota_admin;

--
-- Name: conversations; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.conversations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    municipality_id uuid,
    phone character varying NOT NULL,
    state character varying DEFAULT 'greeting'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.conversations FORCE ROW LEVEL SECURITY;


ALTER TABLE public.conversations OWNER TO rota_admin;

--
-- Name: dashboard_metrics; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.dashboard_metrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    dimension character varying NOT NULL,
    key character varying NOT NULL,
    municipality_id uuid NOT NULL,
    period character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    value integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.dashboard_metrics FORCE ROW LEVEL SECURITY;


ALTER TABLE public.dashboard_metrics OWNER TO rota_admin;

--
-- Name: domain_events; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.domain_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    municipality_id uuid,
    name character varying NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    published_at timestamp(6) without time zone,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.domain_events FORCE ROW LEVEL SECURITY;


ALTER TABLE public.domain_events OWNER TO rota_admin;

--
-- Name: identities; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    provider character varying NOT NULL,
    provider_uid character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL
);


ALTER TABLE public.identities OWNER TO rota_app;

--
-- Name: inbound_messages; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.inbound_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    "from" character varying NOT NULL,
    kind character varying NOT NULL,
    message_id character varying NOT NULL,
    municipality_id uuid NOT NULL,
    raw text NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.inbound_messages FORCE ROW LEVEL SECURITY;


ALTER TABLE public.inbound_messages OWNER TO rota_admin;

--
-- Name: invitations; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.invitations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    accepted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    email character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    invited_by_id uuid NOT NULL,
    municipality_id uuid,
    role character varying NOT NULL,
    token character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.invitations OWNER TO rota_app;

--
-- Name: memberships; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    granted_at timestamp(6) without time zone NOT NULL,
    granted_by_id uuid,
    municipality_id uuid,
    revoked_at timestamp(6) without time zone,
    role character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    user_id uuid NOT NULL,
    CONSTRAINT ck_memberships_operator_global CHECK ((((role)::text <> 'platform_operator'::text) OR (municipality_id IS NULL))),
    CONSTRAINT ck_memberships_role CHECK (((role)::text = ANY (ARRAY[('platform_operator'::character varying)::text, ('municipal_admin'::character varying)::text, ('protocol_author'::character varying)::text, ('protocol_publisher'::character varying)::text, ('viewer'::character varying)::text])))
);


ALTER TABLE public.memberships OWNER TO rota_app;

--
-- Name: municipalities; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.municipalities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    ibge_code character varying,
    name character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    slug character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    uf character varying(2),
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ck_municipality_status CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('suspended'::character varying)::text])))
);


ALTER TABLE public.municipalities OWNER TO rota_app;

--
-- Name: municipality_channels; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.municipality_channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    access_token text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    display_phone_number character varying NOT NULL,
    municipality_id uuid NOT NULL,
    phone_number_id character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    waba_id character varying NOT NULL
);


ALTER TABLE public.municipality_channels OWNER TO rota_app;

--
-- Name: outbound_messages; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.outbound_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    idempotency_key character varying NOT NULL,
    municipality_id uuid NOT NULL,
    response text,
    status integer NOT NULL,
    template jsonb NOT NULL,
    "to" character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.outbound_messages FORCE ROW LEVEL SECURITY;


ALTER TABLE public.outbound_messages OWNER TO rota_admin;

--
-- Name: processed_events; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.processed_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    consumer character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    event_id character varying NOT NULL,
    municipality_id uuid NOT NULL,
    processed_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.processed_events OWNER TO rota_app;

--
-- Name: protocol_definitions; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.protocol_definitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    activated_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    definition jsonb NOT NULL,
    municipality_id uuid,
    name character varying NOT NULL,
    retired_at timestamp(6) without time zone,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    version integer NOT NULL,
    CONSTRAINT ck_protocol_definitions_status CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('in_review'::character varying)::text, ('published'::character varying)::text, ('active'::character varying)::text, ('retired'::character varying)::text])))
);

ALTER TABLE ONLY public.protocol_definitions FORCE ROW LEVEL SECURITY;


ALTER TABLE public.protocol_definitions OWNER TO rota_admin;

--
-- Name: report_snapshots; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.report_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone,
    municipality_id uuid NOT NULL,
    outcome jsonb NOT NULL,
    payload jsonb NOT NULL,
    protocol_definition_id uuid NOT NULL,
    signature character varying NOT NULL,
    token character varying NOT NULL,
    triage_id uuid NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.report_snapshots FORCE ROW LEVEL SECURITY;


ALTER TABLE public.report_snapshots OWNER TO rota_admin;

--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


ALTER TABLE public.schema_migrations OWNER TO rota_app;

--
-- Name: sessions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    ip_address character varying,
    mfa_verified_at timestamp(6) without time zone,
    updated_at timestamp(6) without time zone NOT NULL,
    user_agent character varying,
    user_id uuid NOT NULL
);


ALTER TABLE public.sessions OWNER TO rota_app;

--
-- Name: solid_cache_entries; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_cache_entries (
    id bigint NOT NULL,
    byte_size integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    key bytea NOT NULL,
    key_hash bigint NOT NULL,
    value bytea NOT NULL
);


ALTER TABLE public.solid_cache_entries OWNER TO rota_app;

--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_cache_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_cache_entries_id_seq OWNER TO rota_app;

--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_cache_entries_id_seq OWNED BY public.solid_cache_entries.id;


--
-- Name: solid_queue_blocked_executions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_blocked_executions (
    id bigint NOT NULL,
    concurrency_key character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    job_id bigint NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    queue_name character varying NOT NULL
);


ALTER TABLE public.solid_queue_blocked_executions OWNER TO rota_app;

--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_blocked_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_blocked_executions_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_blocked_executions_id_seq OWNED BY public.solid_queue_blocked_executions.id;


--
-- Name: solid_queue_claimed_executions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_claimed_executions (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    job_id bigint NOT NULL,
    process_id bigint
);


ALTER TABLE public.solid_queue_claimed_executions OWNER TO rota_app;

--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_claimed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_claimed_executions_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_claimed_executions_id_seq OWNED BY public.solid_queue_claimed_executions.id;


--
-- Name: solid_queue_failed_executions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_failed_executions (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    error text,
    job_id bigint NOT NULL
);


ALTER TABLE public.solid_queue_failed_executions OWNER TO rota_app;

--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_failed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_failed_executions_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_failed_executions_id_seq OWNED BY public.solid_queue_failed_executions.id;


--
-- Name: solid_queue_jobs; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_jobs (
    id bigint NOT NULL,
    active_job_id character varying,
    arguments text,
    class_name character varying NOT NULL,
    concurrency_key character varying,
    created_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone,
    priority integer DEFAULT 0 NOT NULL,
    queue_name character varying NOT NULL,
    scheduled_at timestamp(6) without time zone,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.solid_queue_jobs OWNER TO rota_app;

--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_jobs_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_jobs_id_seq OWNED BY public.solid_queue_jobs.id;


--
-- Name: solid_queue_pauses; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_pauses (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    queue_name character varying NOT NULL
);


ALTER TABLE public.solid_queue_pauses OWNER TO rota_app;

--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_pauses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_pauses_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_pauses_id_seq OWNED BY public.solid_queue_pauses.id;


--
-- Name: solid_queue_processes; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_processes (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    hostname character varying,
    kind character varying NOT NULL,
    last_heartbeat_at timestamp(6) without time zone NOT NULL,
    metadata text,
    name character varying NOT NULL,
    pid integer NOT NULL,
    supervisor_id bigint
);


ALTER TABLE public.solid_queue_processes OWNER TO rota_app;

--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_processes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_processes_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_processes_id_seq OWNED BY public.solid_queue_processes.id;


--
-- Name: solid_queue_ready_executions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_ready_executions (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    job_id bigint NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    queue_name character varying NOT NULL
);


ALTER TABLE public.solid_queue_ready_executions OWNER TO rota_app;

--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_ready_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_ready_executions_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_ready_executions_id_seq OWNED BY public.solid_queue_ready_executions.id;


--
-- Name: solid_queue_recurring_executions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_recurring_executions (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    job_id bigint NOT NULL,
    run_at timestamp(6) without time zone NOT NULL,
    task_key character varying NOT NULL
);


ALTER TABLE public.solid_queue_recurring_executions OWNER TO rota_app;

--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_recurring_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_recurring_executions_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_recurring_executions_id_seq OWNED BY public.solid_queue_recurring_executions.id;


--
-- Name: solid_queue_recurring_tasks; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_recurring_tasks (
    id bigint NOT NULL,
    arguments text,
    class_name character varying,
    command character varying(2048),
    created_at timestamp(6) without time zone NOT NULL,
    description text,
    key character varying NOT NULL,
    priority integer DEFAULT 0,
    queue_name character varying,
    schedule character varying NOT NULL,
    static boolean DEFAULT true NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.solid_queue_recurring_tasks OWNER TO rota_app;

--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_recurring_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_recurring_tasks_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_recurring_tasks_id_seq OWNED BY public.solid_queue_recurring_tasks.id;


--
-- Name: solid_queue_scheduled_executions; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_scheduled_executions (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    job_id bigint NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    queue_name character varying NOT NULL,
    scheduled_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.solid_queue_scheduled_executions OWNER TO rota_app;

--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_scheduled_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_scheduled_executions_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_scheduled_executions_id_seq OWNED BY public.solid_queue_scheduled_executions.id;


--
-- Name: solid_queue_semaphores; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.solid_queue_semaphores (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    key character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    value integer DEFAULT 1 NOT NULL
);


ALTER TABLE public.solid_queue_semaphores OWNER TO rota_app;

--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE; Schema: public; Owner: rota_app
--

CREATE SEQUENCE public.solid_queue_semaphores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.solid_queue_semaphores_id_seq OWNER TO rota_app;

--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: rota_app
--

ALTER SEQUENCE public.solid_queue_semaphores_id_seq OWNED BY public.solid_queue_semaphores.id;


--
-- Name: triages; Type: TABLE; Schema: public; Owner: rota_admin
--

CREATE TABLE public.triages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    answers jsonb DEFAULT '{}'::jsonb NOT NULL,
    completed_at timestamp(6) without time zone,
    conversation_id uuid NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    current_step character varying,
    municipality_id uuid NOT NULL,
    outcome jsonb,
    priority integer,
    protocol_definition_id uuid NOT NULL,
    protocol_name character varying NOT NULL,
    status character varying DEFAULT 'in_progress'::character varying NOT NULL,
    tier character varying,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ck_triagens_status CHECK (((status)::text = ANY (ARRAY[('in_progress'::character varying)::text, ('completed'::character varying)::text, ('aborted_by_revocation'::character varying)::text])))
);

ALTER TABLE ONLY public.triages FORCE ROW LEVEL SECURITY;


ALTER TABLE public.triages OWNER TO rota_admin;

--
-- Name: unknown_channels; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.unknown_channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    first_seen_at timestamp(6) without time zone NOT NULL,
    hits integer DEFAULT 1 NOT NULL,
    last_seen_at timestamp(6) without time zone NOT NULL,
    phone_number_id character varying NOT NULL,
    sample_change jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.unknown_channels OWNER TO rota_app;

--
-- Name: users; Type: TABLE; Schema: public; Owner: rota_app
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    deactivated_at timestamp(6) without time zone,
    email_address character varying NOT NULL,
    otp_enabled boolean DEFAULT false NOT NULL,
    otp_recovery_codes jsonb DEFAULT '[]'::jsonb NOT NULL,
    otp_secret character varying,
    password_digest character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


ALTER TABLE public.users OWNER TO rota_app;

--
-- Name: solid_cache_entries id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_cache_entries ALTER COLUMN id SET DEFAULT nextval('public.solid_cache_entries_id_seq'::regclass);


--
-- Name: solid_queue_blocked_executions id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_blocked_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_blocked_executions_id_seq'::regclass);


--
-- Name: solid_queue_claimed_executions id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_claimed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_claimed_executions_id_seq'::regclass);


--
-- Name: solid_queue_failed_executions id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_failed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_failed_executions_id_seq'::regclass);


--
-- Name: solid_queue_jobs id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_jobs ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_jobs_id_seq'::regclass);


--
-- Name: solid_queue_pauses id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_pauses ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_pauses_id_seq'::regclass);


--
-- Name: solid_queue_processes id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_processes ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_processes_id_seq'::regclass);


--
-- Name: solid_queue_ready_executions id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_ready_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_ready_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_executions id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_recurring_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_tasks id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_tasks_id_seq'::regclass);


--
-- Name: solid_queue_scheduled_executions id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_scheduled_executions_id_seq'::regclass);


--
-- Name: solid_queue_semaphores id; Type: DEFAULT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_semaphores ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_semaphores_id_seq'::regclass);


--
-- Name: alert_recipients alert_recipients_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.alert_recipients
    ADD CONSTRAINT alert_recipients_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: authors authors_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.authors
    ADD CONSTRAINT authors_pkey PRIMARY KEY (id);


--
-- Name: consent_terms consent_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.consent_terms
    ADD CONSTRAINT consent_terms_pkey PRIMARY KEY (id);


--
-- Name: consents consents_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.consents
    ADD CONSTRAINT consents_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: dashboard_metrics dashboard_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.dashboard_metrics
    ADD CONSTRAINT dashboard_metrics_pkey PRIMARY KEY (id);


--
-- Name: domain_events domain_events_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.domain_events
    ADD CONSTRAINT domain_events_pkey PRIMARY KEY (id);


--
-- Name: identities identities_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.identities
    ADD CONSTRAINT identities_pkey PRIMARY KEY (id);


--
-- Name: inbound_messages inbound_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.inbound_messages
    ADD CONSTRAINT inbound_messages_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: municipalities municipalities_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.municipalities
    ADD CONSTRAINT municipalities_pkey PRIMARY KEY (id);


--
-- Name: municipality_channels municipality_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.municipality_channels
    ADD CONSTRAINT municipality_channels_pkey PRIMARY KEY (id);


--
-- Name: outbound_messages outbound_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.outbound_messages
    ADD CONSTRAINT outbound_messages_pkey PRIMARY KEY (id);


--
-- Name: processed_events processed_events_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.processed_events
    ADD CONSTRAINT processed_events_pkey PRIMARY KEY (id);


--
-- Name: protocol_definitions protocol_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.protocol_definitions
    ADD CONSTRAINT protocol_definitions_pkey PRIMARY KEY (id);


--
-- Name: report_snapshots report_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.report_snapshots
    ADD CONSTRAINT report_snapshots_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: solid_cache_entries solid_cache_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_cache_entries
    ADD CONSTRAINT solid_cache_entries_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_blocked_executions solid_queue_blocked_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT solid_queue_blocked_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_claimed_executions solid_queue_claimed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT solid_queue_claimed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_failed_executions solid_queue_failed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT solid_queue_failed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_jobs solid_queue_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_jobs
    ADD CONSTRAINT solid_queue_jobs_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_pauses solid_queue_pauses_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_pauses
    ADD CONSTRAINT solid_queue_pauses_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_processes solid_queue_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_processes
    ADD CONSTRAINT solid_queue_processes_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_ready_executions solid_queue_ready_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT solid_queue_ready_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_executions solid_queue_recurring_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT solid_queue_recurring_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_tasks solid_queue_recurring_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks
    ADD CONSTRAINT solid_queue_recurring_tasks_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_scheduled_executions solid_queue_scheduled_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT solid_queue_scheduled_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_semaphores solid_queue_semaphores_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_semaphores
    ADD CONSTRAINT solid_queue_semaphores_pkey PRIMARY KEY (id);


--
-- Name: triages triages_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.triages
    ADD CONSTRAINT triages_pkey PRIMARY KEY (id);


--
-- Name: unknown_channels unknown_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.unknown_channels
    ADD CONSTRAINT unknown_channels_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_consents_one_active_per_conversation; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_consents_one_active_per_conversation ON public.consents USING btree (conversation_id, revoked_at) WHERE (revoked_at IS NULL);


--
-- Name: idx_conversations_active_per_tenant_phone; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_conversations_active_per_tenant_phone ON public.conversations USING btree (municipality_id, phone) WHERE ((state)::text = ANY (ARRAY[('awaiting_consent'::character varying)::text, ('consented'::character varying)::text, ('greeting'::character varying)::text]));


--
-- Name: idx_dashboard_metrics_dim_period_key; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_dashboard_metrics_dim_period_key ON public.dashboard_metrics USING btree (municipality_id, dimension, period, key);


--
-- Name: idx_domain_events_pending; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX idx_domain_events_pending ON public.domain_events USING btree (occurred_at) WHERE (published_at IS NULL);


--
-- Name: idx_memberships_unique_active; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX idx_memberships_unique_active ON public.memberships USING btree (user_id, COALESCE(municipality_id, '00000000-0000-0000-0000-000000000000'::uuid), role) WHERE (revoked_at IS NULL);


--
-- Name: idx_protocol_definitions_name_version_muni; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_protocol_definitions_name_version_muni ON public.protocol_definitions USING btree (name, version, municipality_id);


--
-- Name: idx_protocol_definitions_one_active_per_name_muni; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_protocol_definitions_one_active_per_name_muni ON public.protocol_definitions USING btree (name, municipality_id) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_report_snapshots_one_per_triagem; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_report_snapshots_one_per_triagem ON public.report_snapshots USING btree (triage_id);


--
-- Name: idx_triagens_one_in_progress_per_conversation; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX idx_triagens_one_in_progress_per_conversation ON public.triages USING btree (conversation_id) WHERE ((status)::text = 'in_progress'::text);


--
-- Name: index_alert_recipients_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_alert_recipients_on_municipality_id ON public.alert_recipients USING btree (municipality_id);


--
-- Name: index_alert_recipients_on_municipality_id_and_escalation_order; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_alert_recipients_on_municipality_id_and_escalation_order ON public.alert_recipients USING btree (municipality_id, escalation_order);


--
-- Name: index_authors_on_email; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_authors_on_email ON public.authors USING btree (email);


--
-- Name: index_authors_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_authors_on_municipality_id ON public.authors USING btree (municipality_id);


--
-- Name: index_authors_on_token; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_authors_on_token ON public.authors USING btree (token);


--
-- Name: index_consent_terms_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_consent_terms_on_municipality_id ON public.consent_terms USING btree (municipality_id);


--
-- Name: index_consent_terms_on_municipality_id_and_version; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_consent_terms_on_municipality_id_and_version ON public.consent_terms USING btree (municipality_id, version);


--
-- Name: index_consents_on_conversation_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_consents_on_conversation_id ON public.consents USING btree (conversation_id);


--
-- Name: index_consents_on_given_at; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_consents_on_given_at ON public.consents USING btree (given_at);


--
-- Name: index_consents_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_consents_on_municipality_id ON public.consents USING btree (municipality_id);


--
-- Name: index_conversations_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_conversations_on_municipality_id ON public.conversations USING btree (municipality_id);


--
-- Name: index_conversations_on_state; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_conversations_on_state ON public.conversations USING btree (state);


--
-- Name: index_dashboard_metrics_on_dimension_and_period; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_dashboard_metrics_on_dimension_and_period ON public.dashboard_metrics USING btree (dimension, period);


--
-- Name: index_dashboard_metrics_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_dashboard_metrics_on_municipality_id ON public.dashboard_metrics USING btree (municipality_id);


--
-- Name: index_domain_events_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_domain_events_on_municipality_id ON public.domain_events USING btree (municipality_id);


--
-- Name: index_domain_events_on_name; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_domain_events_on_name ON public.domain_events USING btree (name);


--
-- Name: index_domain_events_on_occurred_at; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_domain_events_on_occurred_at ON public.domain_events USING btree (occurred_at);


--
-- Name: index_identities_on_provider_and_provider_uid; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_identities_on_provider_and_provider_uid ON public.identities USING btree (provider, provider_uid);


--
-- Name: index_identities_on_user_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_identities_on_user_id ON public.identities USING btree (user_id);


--
-- Name: index_inbound_messages_on_created_at; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_inbound_messages_on_created_at ON public.inbound_messages USING btree (created_at);


--
-- Name: index_inbound_messages_on_from; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_inbound_messages_on_from ON public.inbound_messages USING btree ("from");


--
-- Name: index_inbound_messages_on_message_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX index_inbound_messages_on_message_id ON public.inbound_messages USING btree (message_id);


--
-- Name: index_inbound_messages_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_inbound_messages_on_municipality_id ON public.inbound_messages USING btree (municipality_id);


--
-- Name: index_invitations_on_invited_by_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_invitations_on_invited_by_id ON public.invitations USING btree (invited_by_id);


--
-- Name: index_invitations_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_invitations_on_municipality_id ON public.invitations USING btree (municipality_id);


--
-- Name: index_invitations_on_token; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_invitations_on_token ON public.invitations USING btree (token);


--
-- Name: index_memberships_on_granted_by_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_memberships_on_granted_by_id ON public.memberships USING btree (granted_by_id);


--
-- Name: index_memberships_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_memberships_on_municipality_id ON public.memberships USING btree (municipality_id);


--
-- Name: index_memberships_on_user_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_memberships_on_user_id ON public.memberships USING btree (user_id);


--
-- Name: index_municipalities_on_ibge_code; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_municipalities_on_ibge_code ON public.municipalities USING btree (ibge_code) WHERE (ibge_code IS NOT NULL);


--
-- Name: index_municipalities_on_slug; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_municipalities_on_slug ON public.municipalities USING btree (slug);


--
-- Name: index_municipality_channels_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_municipality_channels_on_municipality_id ON public.municipality_channels USING btree (municipality_id);


--
-- Name: index_municipality_channels_on_municipality_id_and_active; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_municipality_channels_on_municipality_id_and_active ON public.municipality_channels USING btree (municipality_id, active);


--
-- Name: index_municipality_channels_on_phone_number_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_municipality_channels_on_phone_number_id ON public.municipality_channels USING btree (phone_number_id);


--
-- Name: index_outbound_messages_on_idempotency_key; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX index_outbound_messages_on_idempotency_key ON public.outbound_messages USING btree (idempotency_key);


--
-- Name: index_outbound_messages_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_outbound_messages_on_municipality_id ON public.outbound_messages USING btree (municipality_id);


--
-- Name: index_outbound_messages_on_status_and_created_at; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_outbound_messages_on_status_and_created_at ON public.outbound_messages USING btree (status, created_at);


--
-- Name: index_outbound_messages_on_to; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_outbound_messages_on_to ON public.outbound_messages USING btree ("to");


--
-- Name: index_processed_events_on_consumer_and_event_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_processed_events_on_consumer_and_event_id ON public.processed_events USING btree (consumer, event_id);


--
-- Name: index_processed_events_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_processed_events_on_municipality_id ON public.processed_events USING btree (municipality_id);


--
-- Name: index_processed_events_on_processed_at; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_processed_events_on_processed_at ON public.processed_events USING btree (processed_at);


--
-- Name: index_protocol_definitions_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_protocol_definitions_on_municipality_id ON public.protocol_definitions USING btree (municipality_id);


--
-- Name: index_report_snapshots_on_expires_at; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_report_snapshots_on_expires_at ON public.report_snapshots USING btree (expires_at);


--
-- Name: index_report_snapshots_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_report_snapshots_on_municipality_id ON public.report_snapshots USING btree (municipality_id);


--
-- Name: index_report_snapshots_on_protocol_definition_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_report_snapshots_on_protocol_definition_id ON public.report_snapshots USING btree (protocol_definition_id);


--
-- Name: index_report_snapshots_on_token; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE UNIQUE INDEX index_report_snapshots_on_token ON public.report_snapshots USING btree (token);


--
-- Name: index_report_snapshots_on_triage_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_report_snapshots_on_triage_id ON public.report_snapshots USING btree (triage_id);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_solid_cache_entries_on_byte_size; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_cache_entries_on_byte_size ON public.solid_cache_entries USING btree (byte_size);


--
-- Name: index_solid_cache_entries_on_key_hash; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_cache_entries_on_key_hash ON public.solid_cache_entries USING btree (key_hash);


--
-- Name: index_solid_cache_entries_on_key_hash_and_byte_size; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_cache_entries_on_key_hash_and_byte_size ON public.solid_cache_entries USING btree (key_hash, byte_size);


--
-- Name: index_solid_queue_blocked_executions_for_maintenance; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_blocked_executions_for_maintenance ON public.solid_queue_blocked_executions USING btree (expires_at, concurrency_key);


--
-- Name: index_solid_queue_blocked_executions_for_release; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_blocked_executions_for_release ON public.solid_queue_blocked_executions USING btree (concurrency_key, priority, job_id);


--
-- Name: index_solid_queue_blocked_executions_on_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_blocked_executions_on_job_id ON public.solid_queue_blocked_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_claimed_executions_on_job_id ON public.solid_queue_claimed_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_process_id_and_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_claimed_executions_on_process_id_and_job_id ON public.solid_queue_claimed_executions USING btree (process_id, job_id);


--
-- Name: index_solid_queue_dispatch_all; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_dispatch_all ON public.solid_queue_scheduled_executions USING btree (scheduled_at, priority, job_id);


--
-- Name: index_solid_queue_failed_executions_on_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_failed_executions_on_job_id ON public.solid_queue_failed_executions USING btree (job_id);


--
-- Name: index_solid_queue_jobs_for_alerting; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_jobs_for_alerting ON public.solid_queue_jobs USING btree (scheduled_at, finished_at);


--
-- Name: index_solid_queue_jobs_for_filtering; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_jobs_for_filtering ON public.solid_queue_jobs USING btree (queue_name, finished_at);


--
-- Name: index_solid_queue_jobs_on_active_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_jobs_on_active_job_id ON public.solid_queue_jobs USING btree (active_job_id);


--
-- Name: index_solid_queue_jobs_on_class_name; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_jobs_on_class_name ON public.solid_queue_jobs USING btree (class_name);


--
-- Name: index_solid_queue_jobs_on_finished_at; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_jobs_on_finished_at ON public.solid_queue_jobs USING btree (finished_at);


--
-- Name: index_solid_queue_pauses_on_queue_name; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_pauses_on_queue_name ON public.solid_queue_pauses USING btree (queue_name);


--
-- Name: index_solid_queue_poll_all; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_poll_all ON public.solid_queue_ready_executions USING btree (priority, job_id);


--
-- Name: index_solid_queue_poll_by_queue; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_poll_by_queue ON public.solid_queue_ready_executions USING btree (queue_name, priority, job_id);


--
-- Name: index_solid_queue_processes_on_last_heartbeat_at; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_processes_on_last_heartbeat_at ON public.solid_queue_processes USING btree (last_heartbeat_at);


--
-- Name: index_solid_queue_processes_on_name_and_supervisor_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_processes_on_name_and_supervisor_id ON public.solid_queue_processes USING btree (name, supervisor_id);


--
-- Name: index_solid_queue_processes_on_supervisor_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_processes_on_supervisor_id ON public.solid_queue_processes USING btree (supervisor_id);


--
-- Name: index_solid_queue_ready_executions_on_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_ready_executions_on_job_id ON public.solid_queue_ready_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_job_id ON public.solid_queue_recurring_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_task_key_and_run_at; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_task_key_and_run_at ON public.solid_queue_recurring_executions USING btree (task_key, run_at);


--
-- Name: index_solid_queue_recurring_tasks_on_key; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_recurring_tasks_on_key ON public.solid_queue_recurring_tasks USING btree (key);


--
-- Name: index_solid_queue_recurring_tasks_on_static; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_recurring_tasks_on_static ON public.solid_queue_recurring_tasks USING btree (static);


--
-- Name: index_solid_queue_scheduled_executions_on_job_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_scheduled_executions_on_job_id ON public.solid_queue_scheduled_executions USING btree (job_id);


--
-- Name: index_solid_queue_semaphores_on_expires_at; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_semaphores_on_expires_at ON public.solid_queue_semaphores USING btree (expires_at);


--
-- Name: index_solid_queue_semaphores_on_key; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_solid_queue_semaphores_on_key ON public.solid_queue_semaphores USING btree (key);


--
-- Name: index_solid_queue_semaphores_on_key_and_value; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE INDEX index_solid_queue_semaphores_on_key_and_value ON public.solid_queue_semaphores USING btree (key, value);


--
-- Name: index_triages_on_conversation_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_conversation_id ON public.triages USING btree (conversation_id);


--
-- Name: index_triages_on_conversation_id_and_created_at; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_conversation_id_and_created_at ON public.triages USING btree (conversation_id, created_at);


--
-- Name: index_triages_on_conversation_id_and_status; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_conversation_id_and_status ON public.triages USING btree (conversation_id, status);


--
-- Name: index_triages_on_municipality_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_municipality_id ON public.triages USING btree (municipality_id);


--
-- Name: index_triages_on_protocol_definition_id; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_protocol_definition_id ON public.triages USING btree (protocol_definition_id);


--
-- Name: index_triages_on_status; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_status ON public.triages USING btree (status);


--
-- Name: index_triages_on_tier; Type: INDEX; Schema: public; Owner: rota_admin
--

CREATE INDEX index_triages_on_tier ON public.triages USING btree (tier);


--
-- Name: index_unknown_channels_on_phone_number_id; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_unknown_channels_on_phone_number_id ON public.unknown_channels USING btree (phone_number_id);


--
-- Name: index_users_on_lower_email; Type: INDEX; Schema: public; Owner: rota_app
--

CREATE UNIQUE INDEX index_users_on_lower_email ON public.users USING btree (lower((email_address)::text));


--
-- Name: memberships fk_rails_04a2a526c7; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_04a2a526c7 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: report_snapshots fk_rails_057431e44b; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.report_snapshots
    ADD CONSTRAINT fk_rails_057431e44b FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: outbound_messages fk_rails_08c6d01d1f; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.outbound_messages
    ADD CONSTRAINT fk_rails_08c6d01d1f FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: report_snapshots fk_rails_09573c72cb; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.report_snapshots
    ADD CONSTRAINT fk_rails_09573c72cb FOREIGN KEY (protocol_definition_id) REFERENCES public.protocol_definitions(id);


--
-- Name: solid_queue_recurring_executions fk_rails_318a5533ed; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT fk_rails_318a5533ed FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: consent_terms fk_rails_3563fcf51b; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.consent_terms
    ADD CONSTRAINT fk_rails_3563fcf51b FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: solid_queue_failed_executions fk_rails_39bbc7a631; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT fk_rails_39bbc7a631 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: memberships fk_rails_4520244a55; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_4520244a55 FOREIGN KEY (granted_by_id) REFERENCES public.users(id);


--
-- Name: processed_events fk_rails_4a13363d21; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.processed_events
    ADD CONSTRAINT fk_rails_4a13363d21 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: solid_queue_blocked_executions fk_rails_4cd34e2228; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT fk_rails_4cd34e2228 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: identities fk_rails_5373344100; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.identities
    ADD CONSTRAINT fk_rails_5373344100 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: dashboard_metrics fk_rails_548dbdc766; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.dashboard_metrics
    ADD CONSTRAINT fk_rails_548dbdc766 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: conversations fk_rails_59003be8ca; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_59003be8ca FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: consents fk_rails_63cdb6cf8b; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.consents
    ADD CONSTRAINT fk_rails_63cdb6cf8b FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: solid_queue_ready_executions fk_rails_81fcbd66af; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT fk_rails_81fcbd66af FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: protocol_definitions fk_rails_83e0cec4ed; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.protocol_definitions
    ADD CONSTRAINT fk_rails_83e0cec4ed FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: report_snapshots fk_rails_988a38bfcd; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.report_snapshots
    ADD CONSTRAINT fk_rails_988a38bfcd FOREIGN KEY (triage_id) REFERENCES public.triages(id);


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: solid_queue_claimed_executions fk_rails_9cfe4d4944; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT fk_rails_9cfe4d4944 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: authors fk_rails_ae8a6793de; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.authors
    ADD CONSTRAINT fk_rails_ae8a6793de FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: domain_events fk_rails_b7fb4f1673; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.domain_events
    ADD CONSTRAINT fk_rails_b7fb4f1673 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: triages fk_rails_b94141a994; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.triages
    ADD CONSTRAINT fk_rails_b94141a994 FOREIGN KEY (protocol_definition_id) REFERENCES public.protocol_definitions(id);


--
-- Name: triages fk_rails_b9e1143a05; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.triages
    ADD CONSTRAINT fk_rails_b9e1143a05 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: municipality_channels fk_rails_bb4d094726; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.municipality_channels
    ADD CONSTRAINT fk_rails_bb4d094726 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: alert_recipients fk_rails_bd06bf6f28; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.alert_recipients
    ADD CONSTRAINT fk_rails_bd06bf6f28 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: solid_queue_scheduled_executions fk_rails_c4316f352d; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT fk_rails_c4316f352d FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: invitations fk_rails_d799c974a1; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_rails_d799c974a1 FOREIGN KEY (invited_by_id) REFERENCES public.users(id);


--
-- Name: inbound_messages fk_rails_d90d24c160; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.inbound_messages
    ADD CONSTRAINT fk_rails_d90d24c160 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: consents fk_rails_dd76819c93; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.consents
    ADD CONSTRAINT fk_rails_dd76819c93 FOREIGN KEY (conversation_id) REFERENCES public.conversations(id);


--
-- Name: triages fk_rails_e9f4b92a09; Type: FK CONSTRAINT; Schema: public; Owner: rota_admin
--

ALTER TABLE ONLY public.triages
    ADD CONSTRAINT fk_rails_e9f4b92a09 FOREIGN KEY (conversation_id) REFERENCES public.conversations(id);


--
-- Name: invitations fk_rails_ec85ec3df2; Type: FK CONSTRAINT; Schema: public; Owner: rota_app
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_rails_ec85ec3df2 FOREIGN KEY (municipality_id) REFERENCES public.municipalities(id);


--
-- Name: consents; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.consents ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: dashboard_metrics; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.dashboard_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: domain_events; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.domain_events ENABLE ROW LEVEL SECURITY;

--
-- Name: inbound_messages; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.inbound_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: outbound_messages; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.outbound_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: protocol_definitions; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.protocol_definitions ENABLE ROW LEVEL SECURITY;

--
-- Name: report_snapshots; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.report_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: consents tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.consents USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: conversations tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.conversations USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: dashboard_metrics tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.dashboard_metrics USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: domain_events tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.domain_events USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: inbound_messages tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.inbound_messages USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: outbound_messages tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.outbound_messages USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: protocol_definitions tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.protocol_definitions USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: report_snapshots tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.report_snapshots USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: triages tenant_isolation; Type: POLICY; Schema: public; Owner: rota_admin
--

CREATE POLICY tenant_isolation ON public.triages USING ((municipality_id = (current_setting('app.municipality_id'::text))::uuid)) WITH CHECK ((municipality_id = (current_setting('app.municipality_id'::text))::uuid));


--
-- Name: triages; Type: ROW SECURITY; Schema: public; Owner: rota_admin
--

ALTER TABLE public.triages ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO rota_app;
GRANT USAGE ON SCHEMA public TO rota_admin;


--
-- Name: TABLE alert_recipients; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.alert_recipients TO rota_admin;


--
-- Name: TABLE ar_internal_metadata; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ar_internal_metadata TO rota_admin;


--
-- Name: TABLE authors; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.authors TO rota_admin;


--
-- Name: TABLE consent_terms; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.consent_terms TO rota_admin;


--
-- Name: TABLE consents; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.consents TO rota_app;


--
-- Name: TABLE conversations; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.conversations TO rota_app;


--
-- Name: TABLE dashboard_metrics; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dashboard_metrics TO rota_app;


--
-- Name: TABLE domain_events; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.domain_events TO rota_app;


--
-- Name: TABLE identities; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.identities TO rota_admin;


--
-- Name: TABLE inbound_messages; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.inbound_messages TO rota_app;


--
-- Name: TABLE invitations; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invitations TO rota_admin;


--
-- Name: TABLE memberships; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.memberships TO rota_admin;


--
-- Name: TABLE municipalities; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.municipalities TO rota_admin;


--
-- Name: TABLE municipality_channels; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.municipality_channels TO rota_admin;


--
-- Name: TABLE outbound_messages; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.outbound_messages TO rota_app;


--
-- Name: TABLE processed_events; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.processed_events TO rota_admin;


--
-- Name: TABLE protocol_definitions; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.protocol_definitions TO rota_app;


--
-- Name: TABLE report_snapshots; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.report_snapshots TO rota_app;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.schema_migrations TO rota_admin;


--
-- Name: TABLE sessions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.sessions TO rota_admin;


--
-- Name: TABLE solid_cache_entries; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_cache_entries TO rota_admin;


--
-- Name: SEQUENCE solid_cache_entries_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_cache_entries_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_blocked_executions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_blocked_executions TO rota_admin;


--
-- Name: SEQUENCE solid_queue_blocked_executions_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_blocked_executions_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_claimed_executions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_claimed_executions TO rota_admin;


--
-- Name: SEQUENCE solid_queue_claimed_executions_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_claimed_executions_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_failed_executions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_failed_executions TO rota_admin;


--
-- Name: SEQUENCE solid_queue_failed_executions_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_failed_executions_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_jobs; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_jobs TO rota_admin;


--
-- Name: SEQUENCE solid_queue_jobs_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_jobs_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_pauses; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_pauses TO rota_admin;


--
-- Name: SEQUENCE solid_queue_pauses_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_pauses_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_processes; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_processes TO rota_admin;


--
-- Name: SEQUENCE solid_queue_processes_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_processes_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_ready_executions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_ready_executions TO rota_admin;


--
-- Name: SEQUENCE solid_queue_ready_executions_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_ready_executions_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_recurring_executions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_recurring_executions TO rota_admin;


--
-- Name: SEQUENCE solid_queue_recurring_executions_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_recurring_executions_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_recurring_tasks; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_recurring_tasks TO rota_admin;


--
-- Name: SEQUENCE solid_queue_recurring_tasks_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_recurring_tasks_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_scheduled_executions; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_scheduled_executions TO rota_admin;


--
-- Name: SEQUENCE solid_queue_scheduled_executions_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_scheduled_executions_id_seq TO rota_admin;


--
-- Name: TABLE solid_queue_semaphores; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_semaphores TO rota_admin;


--
-- Name: SEQUENCE solid_queue_semaphores_id_seq; Type: ACL; Schema: public; Owner: rota_app
--

GRANT ALL ON SEQUENCE public.solid_queue_semaphores_id_seq TO rota_admin;


--
-- Name: TABLE triages; Type: ACL; Schema: public; Owner: rota_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.triages TO rota_app;


--
-- Name: TABLE unknown_channels; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.unknown_channels TO rota_admin;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: rota_app
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO rota_admin;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO rota_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO rota_admin;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES  TO rota_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES  TO rota_admin;


--
-- PostgreSQL database dump complete
--

\unrestrict LQXWUQuhdQui11odJCkYWFtLWahaIdJMlOpGcpffEZjukCOKZmWKEltbTsiKUkN

