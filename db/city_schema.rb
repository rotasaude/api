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

ActiveRecord::Schema[8.1].define(version: 2026_10_02_300001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
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

  create_table "analytics_daily_facts", force: :cascade do |t|
    t.datetime "consolidated_at", null: false
    t.date "day", null: false
    t.string "dim", default: "", null: false
    t.uuid "health_unit_id"
    t.string "metric", null: false
    t.uuid "neighborhood_id"
    t.string "protocol_name"
    t.integer "protocol_version"
    t.string "question_id"
    t.string "tier"
    t.integer "value", null: false
    t.index ["day", "metric", "health_unit_id", "neighborhood_id", "protocol_name", "protocol_version", "tier", "question_id", "dim"], name: "idx_analytics_facts_cell", unique: true, nulls_not_distinct: true
    t.index ["metric", "day"], name: "idx_analytics_facts_metric_day"
    t.index ["metric", "health_unit_id", "day"], name: "idx_analytics_facts_metric_unit_day"
    t.index ["metric", "neighborhood_id", "day"], name: "idx_analytics_facts_metric_neighborhood_day"
    t.check_constraint "metric::text = ANY (ARRAY['triage.started', 'triage.completed', 'triage.aborted', 'attendance.checked_in', 'attendance.closed', 'attendance.wait', 'appointment.ended', 'request.opened', 'request.closed', 'calibration.outcome', 'epi.answer']::text[])", name: "ck_analytics_facts_metric"
    t.check_constraint "value >= 1", name: "ck_analytics_facts_value"
  end

  create_table "analytics_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "error", limit: 500
    t.datetime "finished_at"
    t.string "kind", null: false
    t.datetime "published_at"
    t.datetime "started_at", null: false
    t.string "status", null: false
    t.date "window_from", null: false
    t.date "window_to", null: false
    t.index ["started_at"], name: "idx_analytics_runs_started_at"
    t.check_constraint "kind::text = ANY (ARRAY['scheduled', 'rebuild']::text[])", name: "ck_analytics_runs_kind"
    t.check_constraint "status::text = ANY (ARRAY['running', 'succeeded', 'failed']::text[])", name: "ck_analytics_runs_status"
    t.check_constraint "window_from <= window_to", name: "ck_analytics_runs_window"
  end

  create_table "appointment_reminders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "appointment_id", null: false
    t.datetime "created_at", null: false
    t.string "error"
    t.string "status", null: false
    t.index ["appointment_id"], name: "index_appointment_reminders_on_appointment_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['sent'::character varying, 'failed'::character varying]::text[])", name: "ck_appointment_reminders_status"
  end

  create_table "appointment_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "citizen_id", null: false
    t.datetime "closed_at"
    t.uuid "closed_by_user_id"
    t.string "closed_reason"
    t.datetime "created_at", null: false
    t.text "dismiss_reason"
    t.string "kind", null: false
    t.text "note"
    t.uuid "origin_attendance_id", null: false
    t.uuid "origin_unit_id", null: false
    t.string "reopened_reason"
    t.uuid "root_triage_id", null: false
    t.string "status", default: "open", null: false
    t.uuid "target_unit_id", null: false
    t.datetime "updated_at", null: false
    t.index ["citizen_id"], name: "index_appointment_requests_on_citizen_id"
    t.index ["closed_by_user_id"], name: "index_appointment_requests_on_closed_by_user_id"
    t.index ["origin_attendance_id"], name: "index_appointment_requests_on_origin_attendance_id", unique: true
    t.index ["origin_unit_id"], name: "index_appointment_requests_on_origin_unit_id"
    t.index ["root_triage_id"], name: "index_appointment_requests_on_root_triage_id"
    t.index ["target_unit_id"], name: "index_appointment_requests_on_target_unit_id"
    t.check_constraint "(closed_reason IS DISTINCT FROM 'dismissed' AND dismiss_reason IS NULL) OR (closed_reason = 'dismissed' AND dismiss_reason IS NOT NULL AND length(btrim(dismiss_reason)) >= 10)", name: "ck_appointment_requests_dismiss_reason"
    t.check_constraint "closed_reason IS NULL OR closed_reason::text = ANY (ARRAY['fulfilled', 'citizen_cancelled', 'dismissed']::text[])", name: "ck_appointment_requests_closed_reason"
    t.check_constraint "(status::text <> 'closed'::text AND closed_reason IS NULL AND closed_at IS NULL) OR (status::text = 'closed'::text AND closed_reason IS NOT NULL AND closed_at IS NOT NULL)", name: "ck_appointment_requests_closing"
    t.check_constraint "kind::text = ANY (ARRAY['return', 'referral']::text[])", name: "ck_appointment_requests_kind"
    t.check_constraint "kind::text <> 'return'::text OR origin_unit_id = target_unit_id", name: "ck_appointment_requests_return_same_unit"
    t.check_constraint "reopened_reason IS NULL OR reopened_reason::text = ANY (ARRAY['expired', 'no_show']::text[])", name: "ck_appointment_requests_reopened_reason"
    t.check_constraint "status::text = ANY (ARRAY['open', 'scheduled', 'closed']::text[])", name: "ck_appointment_requests_status"
  end

  create_table "appointments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "cancel_reason"
    t.uuid "citizen_id", null: false
    t.datetime "confirmation_deadline_at"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.uuid "health_unit_id", null: false
    t.uuid "request_id", null: false
    t.datetime "scheduled_at", null: false
    t.uuid "scheduled_by_user_id", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["citizen_id"], name: "index_appointments_on_citizen_id"
    t.index ["health_unit_id", "scheduled_at"], name: "idx_appointments_unit_time"
    t.index ["health_unit_id"], name: "index_appointments_on_health_unit_id"
    t.index ["request_id"], name: "idx_appointments_one_live_per_request", unique: true, where: "status IN ('scheduled', 'confirmed')"
    t.index ["request_id"], name: "index_appointments_on_request_id"
    t.index ["scheduled_by_user_id"], name: "index_appointments_on_scheduled_by_user_id"
    t.check_constraint "(status::text <> 'cancelled_by_citizen'::text AND cancel_reason IS NULL) OR (status::text = 'cancelled_by_citizen'::text AND cancel_reason IS NOT NULL AND length(btrim(cancel_reason)) >= 10)", name: "ck_appointments_cancel_reason"
    t.check_constraint "status::text <> 'scheduled'::text OR confirmation_deadline_at IS NOT NULL", name: "ck_appointments_deadline"
    t.check_constraint "(status::text = ANY (ARRAY['scheduled', 'confirmed']::text[])) = (ended_at IS NULL)", name: "ck_appointments_ended"
    t.check_constraint "status::text = ANY (ARRAY['scheduled', 'confirmed', 'checked_in', 'cancelled_by_citizen', 'expired', 'no_show']::text[])", name: "ck_appointments_status"
  end

  create_table "attendances", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "appointment_id"
    t.datetime "called_at"
    t.uuid "called_by_user_id"
    t.datetime "checked_in_at", null: false
    t.uuid "checked_in_by_user_id", null: false
    t.string "check_in_method", null: false
    t.uuid "citizen_id", null: false
    t.datetime "closed_at"
    t.uuid "closed_by_user_id"
    t.datetime "created_at", null: false
    t.text "exception_reason"
    t.uuid "health_unit_id", null: false
    t.string "outcome"
    t.text "referral_note"
    t.uuid "referral_unit_id"
    t.string "status", default: "waiting", null: false
    t.uuid "triage_id"
    t.index ["appointment_id"], name: "index_attendances_on_appointment_id", unique: true
    t.index ["called_by_user_id"], name: "index_attendances_on_called_by_user_id"
    t.index ["checked_in_by_user_id"], name: "index_attendances_on_checked_in_by_user_id"
    t.index ["citizen_id"], name: "index_attendances_on_citizen_id"
    t.index ["closed_by_user_id"], name: "index_attendances_on_closed_by_user_id"
    t.index ["health_unit_id"], name: "index_attendances_on_health_unit_id"
    t.index ["referral_unit_id"], name: "index_attendances_on_referral_unit_id"
    t.index ["triage_id"], name: "index_attendances_on_triage_id", unique: true
    t.check_constraint "check_in_method::text = ANY (ARRAY['code', 'cpf_exception']::text[])", name: "ck_attendances_method"
    t.check_constraint "(check_in_method::text = 'code'::text AND exception_reason IS NULL) OR (check_in_method::text = 'cpf_exception'::text AND exception_reason IS NOT NULL AND length(btrim(exception_reason)) >= 10)", name: "ck_attendances_exception_reason"
    t.check_constraint "(called_by_user_id IS NULL) = (called_at IS NULL)", name: "ck_attendances_calling"
    t.check_constraint "(status::text = 'waiting'::text AND called_at IS NULL AND outcome IS NULL AND closed_by_user_id IS NULL AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR (status::text = 'in_care'::text AND called_at IS NOT NULL AND outcome IS NULL AND closed_by_user_id IS NULL AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR (status::text = 'closed'::text AND outcome IS NOT NULL AND closed_by_user_id IS NOT NULL AND closed_at IS NOT NULL)", name: "ck_attendances_closing"
    t.check_constraint "(triage_id IS NULL) <> (appointment_id IS NULL)", name: "ck_attendances_origin"
    t.check_constraint "outcome IS NULL OR outcome::text = ANY (ARRAY['discharged', 'referred', 'return', 'left']::text[])", name: "ck_attendances_outcome"
    t.check_constraint "((outcome IS NULL OR outcome::text = ANY (ARRAY['discharged', 'left']::text[])) AND referral_unit_id IS NULL AND referral_note IS NULL) OR (outcome = 'referred' AND (referral_unit_id IS NOT NULL OR (referral_note IS NOT NULL AND length(btrim(referral_note)) > 0))) OR (outcome = 'return' AND referral_unit_id IS NULL)", name: "ck_attendances_referral"
    t.check_constraint "status::text = ANY (ARRAY['waiting', 'in_care', 'closed']::text[])", name: "ck_attendances_status"
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

  create_table "campaign_recipients", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "campaign_id", null: false
    t.uuid "citizen_id", null: false
    t.datetime "created_at", null: false
    t.datetime "notice_read_at"
    t.string "sms_error", limit: 200
    t.datetime "sms_sent_at"
    t.string "sms_status", null: false
    t.index ["campaign_id", "citizen_id"], name: "idx_campaign_recipients_pair", unique: true
    t.index ["campaign_id", "sms_status"], name: "idx_campaign_recipients_sms"
    t.index ["citizen_id"], name: "index_campaign_recipients_on_citizen_id"
    t.check_constraint "sms_status::text = ANY (ARRAY['not_opted_in', 'duplicate_phone', 'pending', 'deferred', 'sent', 'failed', 'unavailable']::text[])", name: "ck_campaign_recipients_sms_status"
  end

  create_table "campaigns", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "audience", null: false
    t.text "body", null: false
    t.datetime "cancelled_at"
    t.uuid "cancelled_by_user_id"
    t.datetime "created_at", null: false
    t.uuid "created_by_user_id", null: false
    t.datetime "dispatched_at"
    t.uuid "dispatched_by_user_id"
    t.string "failure_reason"
    t.integer "phones_count"
    t.integer "recipients_count"
    t.datetime "send_at"
    t.boolean "sms_enabled"
    t.string "status", default: "draft", null: false
    t.string "title", limit: 120, null: false
    t.datetime "updated_at", null: false
    t.index ["cancelled_by_user_id"], name: "index_campaigns_on_cancelled_by_user_id"
    t.index ["created_at"], name: "index_campaigns_on_created_at"
    t.index ["created_by_user_id"], name: "index_campaigns_on_created_by_user_id"
    t.index ["dispatched_by_user_id"], name: "index_campaigns_on_dispatched_by_user_id"
    t.index ["status", "send_at"], name: "idx_campaigns_status_send_at"
    t.check_constraint "status::text = ANY (ARRAY['draft', 'scheduled', 'sending', 'sent', 'cancelled', 'failed']::text[])", name: "ck_campaigns_status"
    t.check_constraint "length(title::text) >= 3 AND length(title::text) <= 120 AND title::text = btrim(title::text)", name: "ck_campaigns_title"
    t.check_constraint "length(body) >= 10 AND length(body) <= 2000", name: "ck_campaigns_body"
    t.check_constraint "status::text <> 'scheduled'::text OR send_at IS NOT NULL", name: "ck_campaigns_send_at"
    t.check_constraint "(status::text = 'failed'::text) = (failure_reason IS NOT NULL) AND (failure_reason IS NULL OR failure_reason::text = 'below_minimum'::text)", name: "ck_campaigns_failure"
    t.check_constraint "(cancelled_by_user_id IS NULL) = (cancelled_at IS NULL) AND (status::text = 'cancelled'::text) = (cancelled_at IS NOT NULL)", name: "ck_campaigns_cancelled"
  end

  create_table "city_profile", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "campaigns_sms_enabled", default: false, null: false
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

  create_table "citizen_contact_preferences", primary_key: "citizen_id", id: :uuid, default: nil, force: :cascade do |t|
    t.boolean "appointment_reminders_muted", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "notices_muted", default: false, null: false
    t.boolean "sms_opt_in", default: false, null: false
    t.datetime "sms_opt_in_changed_at"
    t.datetime "updated_at", null: false
  end

  create_table "citizen_erasure_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cpf", null: false
    t.datetime "created_at", null: false
    t.uuid "decided_by_user_id"
    t.timestamptz "decided_at"
    t.boolean "document_checked", null: false
    t.uuid "presented_citizen_id", null: false
    t.text "reject_reason"
    t.uuid "requested_by_user_id", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["cpf"], name: "idx_citizen_erasure_requests_one_pending", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["cpf"], name: "index_citizen_erasure_requests_on_cpf"
    t.index ["decided_by_user_id"], name: "index_citizen_erasure_requests_on_decided_by_user_id"
    t.index ["presented_citizen_id"], name: "index_citizen_erasure_requests_on_presented_citizen_id"
    t.index ["requested_by_user_id"], name: "index_citizen_erasure_requests_on_requested_by_user_id"
    t.check_constraint "((status)::text = 'pending'::text) = (decided_at IS NULL)", name: "ck_citizen_erasure_requests_decision"
    t.check_constraint "(status)::text <> 'rejected'::text OR length(btrim(COALESCE(reject_reason, ''::text))) >= 10", name: "ck_citizen_erasure_requests_reason"
    t.check_constraint "status IN ('pending', 'confirmed', 'rejected', 'retained')", name: "ck_citizen_erasure_requests_status"
    t.check_constraint "document_checked", name: "ck_citizen_erasure_requests_document"
  end

  create_table "citizen_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_seen_at"
    t.string "phone", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["phone"], name: "index_citizen_sessions_on_phone"
    t.index ["token_digest"], name: "index_citizen_sessions_on_token_digest", unique: true
  end

  create_table "citizen_verification_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "appointment_id"
    t.integer "attempts", default: 0, null: false
    t.uuid "citizen_id", null: false
    t.string "code_digest", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "purpose", default: "verification", null: false
    t.uuid "triage_id"
    t.datetime "updated_at", null: false
    t.index ["appointment_id"], name: "index_citizen_verification_codes_on_appointment_id"
    t.index ["citizen_id"], name: "index_citizen_verification_codes_on_citizen_id"
    t.index ["triage_id"], name: "index_citizen_verification_codes_on_triage_id"
    t.check_constraint "purpose::text = ANY (ARRAY['verification', 'check_in']::text[])", name: "ck_citizen_verification_codes_purpose"
    t.check_constraint "(purpose::text = 'verification'::text AND triage_id IS NULL AND appointment_id IS NULL) OR (purpose::text = 'check_in'::text AND (triage_id IS NULL) <> (appointment_id IS NULL))", name: "ck_citizen_verification_codes_purpose_target"
  end

  create_table "citizen_verifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "citizen_id", null: false
    t.datetime "created_at", null: false
    t.text "revoke_reason"
    t.datetime "revoked_at"
    t.uuid "revoked_by_user_id"
    t.datetime "verified_at", null: false
    t.uuid "verified_by_user_id", null: false
    t.index ["citizen_id"], name: "idx_citizen_verifications_one_active", unique: true, where: "(revoked_at IS NULL)"
    t.index ["citizen_id"], name: "index_citizen_verifications_on_citizen_id"
    t.index ["revoked_by_user_id"], name: "index_citizen_verifications_on_revoked_by_user_id"
    t.index ["verified_by_user_id"], name: "index_citizen_verifications_on_verified_by_user_id"
    t.check_constraint "revoked_at IS NULL AND revoked_by_user_id IS NULL AND revoke_reason IS NULL OR revoked_at IS NOT NULL AND revoked_by_user_id IS NOT NULL AND revoke_reason IS NOT NULL AND length(btrim(revoke_reason)) >= 10", name: "ck_citizen_verifications_revocation"
  end

  create_table "citizens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cpf", null: false
    t.datetime "created_at", null: false
    t.timestamptz "erased_at"
    t.uuid "neighborhood_id"
    t.string "phone", null: false
    t.datetime "updated_at", null: false
    t.string "verification_level", default: "declared", null: false
    t.index ["cpf", "phone"], name: "index_citizens_on_cpf_and_phone", unique: true
    t.index ["neighborhood_id"], name: "index_citizens_on_neighborhood_id"
    t.index ["phone"], name: "index_citizens_on_phone"
    t.check_constraint "(verification_level)::text = ANY (ARRAY['declared'::text, 'verified'::text])", name: "ck_citizens_verification_level"
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
    t.string "channel", default: "whatsapp", null: false
    t.uuid "citizen_id"
    t.datetime "created_at", null: false
    t.string "last_answer_key"
    t.string "phone", null: false
    t.string "state", default: "greeting", null: false
    t.datetime "updated_at", null: false
    t.index ["citizen_id"], name: "idx_conversations_active_citizen", unique: true, where: "(((channel)::text = 'web'::text) AND ((state)::text = ANY (ARRAY['greeting'::text, 'awaiting_consent'::text, 'consented'::text])))"
    t.index ["citizen_id"], name: "index_conversations_on_citizen_id"
    t.index ["phone"], name: "idx_conversations_active_phone", unique: true, where: "(((channel)::text = 'whatsapp'::text) AND ((state)::text = ANY (ARRAY['greeting'::text, 'awaiting_consent'::text, 'consented'::text])))"
    t.index ["state"], name: "index_conversations_on_state"
    t.check_constraint "(channel)::text = ANY (ARRAY['whatsapp'::text, 'web'::text])", name: "ck_conversations_channel"
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

  create_table "health_units", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "address_complement", limit: 80
    t.string "address_number", limit: 20
    t.string "address_street", limit: 160
    t.string "address_zip", limit: 8
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.uuid "neighborhood_id"
    t.datetime "updated_at", null: false
    t.index "lower((name)::text)", name: "idx_health_units_name_ci", unique: true
    t.index ["neighborhood_id"], name: "index_health_units_on_neighborhood_id"
    t.check_constraint "address_zip IS NULL OR address_zip::text ~ '^[0-9]{8}$'::text", name: "ck_health_units_address_zip"
    t.check_constraint "kind::text = ANY (ARRAY['ubs', 'upa', 'hospital', 'other']::text[])", name: "ck_health_units_kind"
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
    t.text "raw"
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
    t.check_constraint "role::text = ANY (ARRAY['analyst'::text, 'campaign_manager'::text, 'citizen_verifier'::text, 'health_professional'::text, 'municipal_admin'::text, 'protocol_author'::text, 'protocol_publisher'::text, 'protocol_reviewer'::text, 'viewer'::text])", name: "ck_memberships_role"
  end

  create_table "neighborhood_coverages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "health_unit_id", null: false
    t.uuid "neighborhood_id", null: false
    t.index ["health_unit_id"], name: "index_neighborhood_coverages_on_health_unit_id"
    t.index ["neighborhood_id", "health_unit_id"], name: "idx_neighborhood_coverages_pair", unique: true
  end

  create_table "neighborhoods", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", limit: 120, null: false
    t.string "seed_key"
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index "lower((name)::text)", name: "idx_neighborhoods_name_ci", unique: true
    t.index ["seed_key"], name: "idx_neighborhoods_seed_key", unique: true, where: "(seed_key IS NOT NULL)"
    t.check_constraint "length(btrim(name::text)) > 0 AND name::text = btrim(name::text)", name: "ck_neighborhoods_name"
    t.check_constraint "source::text = ANY (ARRAY['seed'::text, 'manual'::text])", name: "ck_neighborhoods_source"
  end

  create_table "otp_challenges", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.string "code_digest", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "phone", null: false
    t.datetime "updated_at", null: false
    t.index ["phone", "created_at"], name: "index_otp_challenges_on_phone_and_created_at"
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

  create_table "professional_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cbo_code", null: false
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.uuid "ended_by_user_id"
    t.uuid "health_unit_id", null: false
    t.uuid "professional_id", null: false
    t.datetime "started_at", null: false
    t.uuid "started_by_user_id", null: false
    t.index ["ended_by_user_id"], name: "index_professional_links_on_ended_by_user_id"
    t.index ["health_unit_id"], name: "index_professional_links_on_health_unit_id"
    t.index ["professional_id", "health_unit_id", "cbo_code"], name: "idx_professional_links_one_active", unique: true, where: "(ended_at IS NULL)"
    t.index ["professional_id"], name: "index_professional_links_on_professional_id"
    t.index ["started_by_user_id"], name: "index_professional_links_on_started_by_user_id"
    t.check_constraint "(ended_at IS NULL) = (ended_by_user_id IS NULL)", name: "ck_professional_links_ending"
    t.check_constraint "cbo_code::text ~ '^[0-9]{6}$'::text", name: "ck_professional_links_cbo_code"
    t.check_constraint "ended_at IS NULL OR ended_at >= started_at", name: "ck_professional_links_order"
  end

  create_table "professional_shifts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cancel_reason"
    t.datetime "cancelled_at"
    t.uuid "cancelled_by_user_id"
    t.datetime "created_at", null: false
    t.uuid "created_by_user_id", null: false
    t.datetime "ends_at", null: false
    t.uuid "professional_id", null: false
    t.uuid "professional_link_id", null: false
    t.datetime "starts_at", null: false
    t.index ["cancelled_by_user_id"], name: "index_professional_shifts_on_cancelled_by_user_id"
    t.index ["created_by_user_id"], name: "index_professional_shifts_on_created_by_user_id"
    t.index ["professional_id"], name: "index_professional_shifts_on_professional_id"
    t.index ["professional_link_id", "starts_at"], name: "idx_professional_shifts_link_start"
    t.index ["professional_link_id"], name: "index_professional_shifts_on_professional_link_id"
    t.check_constraint "cancelled_at IS NULL AND cancelled_by_user_id IS NULL AND cancel_reason IS NULL OR cancelled_at IS NOT NULL AND cancelled_by_user_id IS NOT NULL AND cancel_reason IS NOT NULL AND length(btrim(cancel_reason::text)) > 0", name: "ck_professional_shifts_cancelling"
    t.check_constraint "ends_at > starts_at AND (ends_at - starts_at) <= 'PT24H'::interval", name: "ck_professional_shifts_window"
    t.exclusion_constraint "professional_id WITH =, tsrange(starts_at, ends_at) WITH &&", where: "cancelled_at IS NULL", using: :gist, name: "excl_professional_shifts_overlap"
  end

  create_table "professionals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cns", null: false
    t.string "contact_email"
    t.string "council", null: false
    t.string "council_state", null: false
    t.datetime "created_at", null: false
    t.string "phone"
    t.string "professional_name", null: false
    t.string "registration_number", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["cns"], name: "idx_professionals_cns", unique: true
    t.index ["council", "council_state", "registration_number"], name: "idx_professionals_registration", unique: true
    t.index ["user_id"], name: "index_professionals_on_user_id", unique: true
    t.check_constraint "council_state::text ~ '^[A-Z]{2}$'::text", name: "ck_professionals_council_state"
    t.check_constraint "length(btrim(professional_name::text)) > 0", name: "ck_professionals_name"
    t.check_constraint "registration_number::text ~ '^[0-9]{1,10}$'::text", name: "ck_professionals_registration_number"
  end

  create_table "protocol_activations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_id"
    t.string "actor_kind", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.uuid "protocol_definition_id", null: false
    t.text "reason"
    t.index ["protocol_definition_id"], name: "index_protocol_activations_on_protocol_definition_id"
    t.check_constraint "(kind::text = 'baseline'::text) = (actor_id IS NULL)", name: "ck_protocol_activations_baseline_has_no_actor"
    t.check_constraint "(kind::text = 'baseline'::text) = (actor_kind::text = 'system'::text)", name: "ck_protocol_activations_system_is_baseline"
    t.check_constraint "actor_kind::text = ANY (ARRAY['user'::text, 'maintainer'::text, 'system'::text])", name: "ck_protocol_activations_actor_kind"
    t.check_constraint "kind::text <> 'emergency_revert'::text OR reason IS NOT NULL AND length(btrim(reason)) > 0", name: "ck_protocol_activations_revert_reason"
    t.check_constraint "kind::text = ANY (ARRAY['signed'::text, 'emergency_revert'::text, 'baseline'::text])", name: "ck_protocol_activations_kind"
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
    t.timestamptz "anonymized_at"
    t.jsonb "answers", default: {}, null: false
    t.datetime "completed_at"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "current_step"
    t.uuid "neighborhood_id"
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
    t.index ["neighborhood_id", "created_at"], name: "idx_triages_neighborhood_created"
    t.index ["protocol_definition_id"], name: "index_triages_on_protocol_definition_id"
    t.index ["status"], name: "index_triages_on_status"
    t.index ["tier"], name: "index_triages_on_tier"
    t.check_constraint "status::text = ANY (ARRAY['in_progress'::character varying::text, 'completed'::character varying::text, 'aborted_by_revocation'::character varying::text, 'aborted_by_timeout'::character varying::text, 'aborted_by_cancellation'::character varying::text])", name: "ck_triagens_status"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email_address", null: false
    t.integer "last_otp_step"
    t.boolean "otp_enabled", default: false, null: false
    t.datetime "otp_pending_at"
    t.jsonb "otp_pending_recovery_codes", default: [], null: false
    t.string "otp_pending_secret"
    t.jsonb "otp_recovery_codes", default: [], null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_users_on_lower_email", unique: true
  end

  add_foreign_key "appointment_reminders", "appointments"
  add_foreign_key "appointment_requests", "attendances", column: "origin_attendance_id"
  add_foreign_key "appointment_requests", "citizens"
  add_foreign_key "appointment_requests", "health_units", column: "origin_unit_id"
  add_foreign_key "appointment_requests", "health_units", column: "target_unit_id"
  add_foreign_key "appointment_requests", "triages", column: "root_triage_id"
  add_foreign_key "appointment_requests", "users", column: "closed_by_user_id"
  add_foreign_key "appointments", "appointment_requests", column: "request_id"
  add_foreign_key "appointments", "citizens"
  add_foreign_key "appointments", "health_units"
  add_foreign_key "appointments", "users", column: "scheduled_by_user_id"
  add_foreign_key "attendances", "appointments"
  add_foreign_key "attendances", "citizens"
  add_foreign_key "attendances", "health_units"
  add_foreign_key "attendances", "health_units", column: "referral_unit_id"
  add_foreign_key "attendances", "triages"
  add_foreign_key "attendances", "users", column: "called_by_user_id"
  add_foreign_key "attendances", "users", column: "checked_in_by_user_id"
  add_foreign_key "attendances", "users", column: "closed_by_user_id"
  add_foreign_key "campaign_recipients", "campaigns"
  add_foreign_key "campaign_recipients", "citizens"
  add_foreign_key "campaigns", "users", column: "cancelled_by_user_id"
  add_foreign_key "campaigns", "users", column: "created_by_user_id"
  add_foreign_key "campaigns", "users", column: "dispatched_by_user_id"
  add_foreign_key "citizen_contact_preferences", "citizens"
  add_foreign_key "citizen_erasure_requests", "citizens", column: "presented_citizen_id"
  add_foreign_key "citizen_erasure_requests", "users", column: "decided_by_user_id"
  add_foreign_key "citizen_erasure_requests", "users", column: "requested_by_user_id"
  add_foreign_key "citizen_verification_codes", "appointments"
  add_foreign_key "citizen_verification_codes", "citizens"
  add_foreign_key "citizen_verification_codes", "triages"
  add_foreign_key "citizen_verifications", "citizens"
  add_foreign_key "citizen_verifications", "users", column: "revoked_by_user_id"
  add_foreign_key "citizen_verifications", "users", column: "verified_by_user_id"
  add_foreign_key "citizens", "neighborhoods"
  add_foreign_key "consents", "conversations"
  add_foreign_key "conversations", "citizens"
  add_foreign_key "health_units", "neighborhoods"
  add_foreign_key "identities", "users"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "users", column: "granted_by_id"
  add_foreign_key "neighborhood_coverages", "health_units"
  add_foreign_key "neighborhood_coverages", "neighborhoods"
  add_foreign_key "professional_links", "health_units"
  add_foreign_key "professional_links", "professionals"
  add_foreign_key "professional_links", "users", column: "ended_by_user_id"
  add_foreign_key "professional_links", "users", column: "started_by_user_id"
  add_foreign_key "professional_shifts", "professional_links"
  add_foreign_key "professional_shifts", "professionals"
  add_foreign_key "professional_shifts", "users", column: "cancelled_by_user_id"
  add_foreign_key "professional_shifts", "users", column: "created_by_user_id"
  add_foreign_key "professionals", "users"
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
  add_foreign_key "triages", "neighborhoods"
  add_foreign_key "triages", "protocol_definitions"
end
