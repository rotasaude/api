# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_18_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "alert_recipients", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "destination", null: false
    t.integer "escalation_order", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["escalation_order"], name: "index_alert_recipients_on_escalation_order"
    t.check_constraint "channel::text = ANY (ARRAY['whatsapp'::character varying::text, 'email'::character varying::text])", name: "ck_alert_recipients_channel"
  end

  create_table "authors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_authors_on_email", unique: true
    t.index ["token"], name: "index_authors_on_token", unique: true
  end

  create_table "city_profile", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ibge_code", limit: 7
    t.string "name", null: false
    t.jsonb "settings", default: {}, null: false
    t.boolean "singleton", default: true, null: false
    t.string "uf", limit: 2
    t.datetime "updated_at", null: false
    t.index ["singleton"], name: "index_city_profile_singleton", unique: true
    t.check_constraint "singleton", name: "ck_city_profile_singleton"
  end

  create_table "consent_terms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "published_at", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["version"], name: "index_consent_terms_on_version", unique: true
  end

  create_table "consents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "channel", null: false
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.text "evidence"
    t.datetime "given_at", null: false
    t.string "policy_text_sha", null: false
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["conversation_id", "revoked_at"], name: "idx_consents_one_active_per_conversation", unique: true, where: "(revoked_at IS NULL)"
    t.index ["conversation_id"], name: "index_consents_on_conversation_id"
    t.index ["given_at"], name: "index_consents_on_given_at"
  end

  create_table "conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "phone", null: false
    t.string "state", default: "greeting", null: false
    t.datetime "updated_at", null: false
    t.index ["phone"], name: "idx_conversations_active_phone", unique: true, where: "((state)::text = ANY (ARRAY[('awaiting_consent'::character varying)::text, ('consented'::character varying)::text, ('greeting'::character varying)::text]))"
    t.index ["state"], name: "index_conversations_on_state"
  end

  create_table "dashboard_metrics", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "dimension", null: false
    t.string "key", null: false
    t.string "period", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 0, null: false
    t.index ["dimension", "period", "key"], name: "idx_dashboard_metrics_dim_period_key", unique: true
    t.index ["dimension", "period"], name: "index_dashboard_metrics_on_dimension_and_period"
  end

  create_table "domain_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "published_at"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_domain_events_on_name"
    t.index ["occurred_at"], name: "idx_domain_events_pending", where: "(published_at IS NULL)"
    t.index ["occurred_at"], name: "index_domain_events_on_occurred_at"
  end

  create_table "identities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.string "provider_uid", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["provider", "provider_uid"], name: "index_identities_on_provider_and_provider_uid", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "inbound_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "from", null: false
    t.string "kind", null: false
    t.string "message_id", null: false
    t.timestamptz "processed_at"
    t.text "raw", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "idx_inbound_messages_unprocessed", where: "(processed_at IS NULL)"
    t.index ["created_at"], name: "index_inbound_messages_on_created_at"
    t.index ["from"], name: "index_inbound_messages_on_from"
    t.index ["message_id"], name: "index_inbound_messages_on_message_id", unique: true
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.uuid "invited_by_id"
    t.string "role", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "granted_at", null: false
    t.uuid "granted_by_id"
    t.datetime "revoked_at"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["granted_by_id"], name: "index_memberships_on_granted_by_id"
    t.index ["user_id", "role"], name: "idx_memberships_unique_active", unique: true, where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.check_constraint "role::text = ANY (ARRAY['municipal_admin'::text, 'protocol_author'::text, 'protocol_publisher'::text, 'protocol_reviewer'::text, 'viewer'::text])", name: "ck_memberships_role"
  end

  create_table "outbound_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "idempotency_key", null: false
    t.text "response"
    t.integer "status", null: false
    t.jsonb "template", null: false
    t.string "to", null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_outbound_messages_on_idempotency_key", unique: true
    t.index ["status", "created_at"], name: "index_outbound_messages_on_status_and_created_at"
    t.index ["to"], name: "index_outbound_messages_on_to"
  end

  create_table "processed_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "consumer", null: false
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.datetime "processed_at", null: false
    t.datetime "updated_at", null: false
    t.index ["consumer", "event_id"], name: "index_processed_events_on_consumer_and_event_id", unique: true
    t.index ["processed_at"], name: "index_processed_events_on_processed_at"
  end

  create_table "protocol_activations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_id", null: false
    t.string "actor_kind", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.uuid "protocol_definition_id", null: false
    t.text "reason"
    t.index ["protocol_definition_id"], name: "index_protocol_activations_on_protocol_definition_id"
    t.check_constraint "actor_kind::text = ANY (ARRAY['user'::text, 'maintainer'::text])", name: "ck_protocol_activations_actor_kind"
    t.check_constraint "kind::text = 'signed'::text OR reason IS NOT NULL AND length(btrim(reason)) > 0", name: "ck_protocol_activations_revert_reason"
    t.check_constraint "kind::text = ANY (ARRAY['signed'::text, 'emergency_revert'::text])", name: "ck_protocol_activations_kind"
  end

  create_table "protocol_contributions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_id", null: false
    t.string "actor_kind", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.uuid "protocol_definition_id", null: false
    t.index ["protocol_definition_id"], name: "index_protocol_contributions_on_protocol_definition_id"
    t.check_constraint "actor_kind::text = ANY (ARRAY['user'::text, 'maintainer'::text])", name: "ck_protocol_contributions_actor_kind"
  end

  create_table "protocol_definitions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.jsonb "definition", null: false
    t.string "name", null: false
    t.datetime "retired_at"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["name", "version"], name: "idx_protocol_definitions_name_version_muni", unique: true
    t.index ["name"], name: "idx_protocol_definitions_one_active_per_name_muni", unique: true, where: "((status)::text = 'active'::text)"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'in_review'::character varying::text, 'published'::character varying::text, 'active'::character varying::text, 'retired'::character varying::text])", name: "ck_protocol_definitions_status"
  end

  create_table "protocol_signatures", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.uuid "protocol_definition_id", null: false
    t.string "purpose", null: false
    t.uuid "signer_user_id", null: false
    t.index ["protocol_definition_id"], name: "index_protocol_signatures_on_protocol_definition_id"
    t.index ["signer_user_id"], name: "index_protocol_signatures_on_signer_user_id"
    t.check_constraint "purpose::text = ANY (ARRAY['publication'::text, 'activation'::text])", name: "ck_protocol_signatures_purpose"
  end

  create_table "report_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.jsonb "outcome", null: false
    t.jsonb "payload", null: false
    t.uuid "protocol_definition_id", null: false
    t.string "signature", null: false
    t.string "token", null: false
    t.uuid "triage_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_report_snapshots_on_expires_at"
    t.index ["protocol_definition_id"], name: "index_report_snapshots_on_protocol_definition_id"
    t.index ["token"], name: "index_report_snapshots_on_token", unique: true
    t.index ["triage_id"], name: "idx_report_snapshots_one_per_triagem", unique: true
    t.index ["triage_id"], name: "index_report_snapshots_on_triage_id"
  end

  create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "mfa_verified_at"
    t.uuid "operator_id"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.uuid "user_id"
    t.index ["operator_id"], name: "index_sessions_on_operator_id"
    t.index ["user_id"], name: "index_sessions_on_user_id"
    t.check_constraint "(user_id IS NULL) <> (operator_id IS NULL)", name: "ck_sessions_exactly_one_actor"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "triages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "answers", default: {}, null: false
    t.datetime "completed_at"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "current_step"
    t.jsonb "outcome"
    t.integer "priority"
    t.uuid "protocol_definition_id", null: false
    t.string "protocol_name", null: false
    t.string "status", default: "in_progress", null: false
    t.string "tier"
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_triages_on_conversation_id_and_created_at"
    t.index ["conversation_id", "status"], name: "index_triages_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "idx_triagens_one_in_progress_per_conversation", unique: true, where: "((status)::text = 'in_progress'::text)"
    t.index ["conversation_id"], name: "index_triages_on_conversation_id"
    t.index ["protocol_definition_id"], name: "index_triages_on_protocol_definition_id"
    t.index ["status"], name: "index_triages_on_status"
    t.index ["tier"], name: "index_triages_on_tier"
    t.check_constraint "status::text = ANY (ARRAY['in_progress'::character varying::text, 'completed'::character varying::text, 'aborted_by_revocation'::character varying::text, 'aborted_by_timeout'::character varying::text, 'aborted_by_cancellation'::character varying::text])", name: "ck_triagens_status"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email_address", null: false
    t.boolean "otp_enabled", default: false, null: false
    t.jsonb "otp_recovery_codes", default: [], null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_users_on_lower_email", unique: true
  end

  add_foreign_key "consents", "conversations"
  add_foreign_key "identities", "users"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "users", column: "granted_by_id"
  add_foreign_key "protocol_activations", "protocol_definitions"
  add_foreign_key "protocol_contributions", "protocol_definitions"
  add_foreign_key "protocol_signatures", "protocol_definitions"
  add_foreign_key "protocol_signatures", "users", column: "signer_user_id"
  add_foreign_key "report_snapshots", "protocol_definitions"
  add_foreign_key "report_snapshots", "triages"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "triages", "conversations"
  add_foreign_key "triages", "protocol_definitions"
end
