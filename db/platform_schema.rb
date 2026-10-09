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

ActiveRecord::Schema[8.1].define(version: 2026_10_08_500001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "ciap2_codes", force: :cascade do |t|
    t.string "code", limit: 3, null: false
    t.text "description", null: false
    t.uuid "release_id", null: false
    t.index ["release_id", "code"], name: "index_ciap2_codes_on_release_id_and_code", unique: true
  end

  create_table "cid10_codes", force: :cascade do |t|
    t.string "code", limit: 4, null: false
    t.text "description", null: false
    t.uuid "release_id", null: false
    t.string "sex_restriction", limit: 1
    t.index ["release_id", "code"], name: "index_cid10_codes_on_release_id_and_code", unique: true
    t.check_constraint "sex_restriction IS NULL OR (sex_restriction::text = ANY (ARRAY['F'::text, 'M'::text]))", name: "ck_cid10_codes_sex"
  end

  create_table "cities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "database_url", null: false
    t.text "encryption_key", null: false
    t.string "name", null: false
    t.string "pec_url", limit: 255
    t.string "record_mode", default: "off", null: false
    t.string "schema_version"
    t.string "slug", null: false
    t.string "status", default: "provisioning", null: false
    t.string "time_zone", default: "America/Sao_Paulo", null: false
    t.string "uf", limit: 2
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_cities_on_slug", unique: true
    t.check_constraint "pec_url IS NULL OR pec_url::text ~ '^https://'::text", name: "ck_cities_pec_url_https"
    t.check_constraint "record_mode::text = ANY (ARRAY['off'::text, 'integrated'::text, 'record'::text])", name: "ck_cities_record_mode"
    t.check_constraint "slug::text ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'::text AND length(slug::text) >= 2 AND length(slug::text) <= 63", name: "ck_cities_slug_is_dns_label"
    t.check_constraint "status::text = ANY (ARRAY['provisioning'::character varying, 'active'::character varying, 'suspended'::character varying, 'archived'::character varying]::text[])", name: "ck_cities_status"
    t.check_constraint "time_zone::text = ANY (ARRAY['America/Noronha'::character varying, 'America/Belem'::character varying, 'America/Fortaleza'::character varying, 'America/Recife'::character varying, 'America/Araguaina'::character varying, 'America/Maceio'::character varying, 'America/Bahia'::character varying, 'America/Sao_Paulo'::character varying, 'America/Santarem'::character varying, 'America/Campo_Grande'::character varying, 'America/Cuiaba'::character varying, 'America/Porto_Velho'::character varying, 'America/Boa_Vista'::character varying, 'America/Manaus'::character varying, 'America/Eirunepe'::character varying, 'America/Rio_Branco'::character varying]::text[])", name: "ck_cities_time_zone"
  end

  create_table "city_analytics_indicators", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "city_id", null: false
    t.string "indicator", null: false
    t.datetime "published_at", null: false
    t.boolean "suppressed", null: false
    t.decimal "value", precision: 8, scale: 2
    t.date "week_start", null: false
    t.index ["city_id", "week_start", "indicator"], name: "idx_city_analytics_indicators_cell", unique: true
    t.index ["week_start"], name: "idx_city_analytics_indicators_week"
    t.check_constraint "EXTRACT(isodow FROM week_start) = 1::numeric", name: "ck_city_analytics_indicators_monday"
    t.check_constraint "indicator::text = ANY (ARRAY['triages_started'::text, 'triages_completed'::text, 'attendances_closed'::text, 'wait_within_30_pct'::text, 'no_show_pct'::text, 'left_pct'::text])", name: "ck_city_analytics_indicators_indicator"
    t.check_constraint "suppressed = (value IS NULL)", name: "ck_city_analytics_indicators_suppressed"
  end

  create_table "city_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.boolean "active", default: true, null: false
    t.uuid "city_id", null: false
    t.datetime "created_at", null: false
    t.string "display_phone_number", null: false
    t.string "phone_number_id", null: false
    t.datetime "updated_at", null: false
    t.string "waba_id", null: false
    t.index ["city_id", "active"], name: "index_city_channels_on_city_id_and_active"
    t.index ["city_id"], name: "index_city_channels_on_city_id"
    t.index ["phone_number_id"], name: "index_city_channels_on_phone_number_id", unique: true
  end

  create_table "city_features", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "changed_at", null: false
    t.uuid "changed_by_maintainer_id", null: false
    t.uuid "city_id", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.index ["city_id", "key"], name: "idx_city_features_city_key", unique: true
  end

  create_table "city_grants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "city_id", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "kind", null: false
    t.uuid "subject_id", null: false
    t.datetime "updated_at", null: false
    t.index ["city_id"], name: "index_city_grants_on_city_id"
    t.check_constraint "kind::text = ANY (ARRAY['operator'::character varying, 'user'::character varying]::text[])", name: "ck_city_grants_kind"
  end

  create_table "city_production_summaries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "accepted", default: 0, null: false
    t.uuid "city_id", null: false
    t.string "competence", limit: 6, null: false
    t.integer "failed", default: 0, null: false
    t.integer "pending", default: 0, null: false
    t.datetime "published_at", null: false
    t.integer "rejected", default: 0, null: false
    t.integer "sending", default: 0, null: false
    t.index ["city_id", "competence"], name: "idx_city_production_summaries_cell", unique: true
    t.check_constraint "competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text", name: "ck_city_production_summaries_competence"
  end

  create_table "cnes_establishments", force: :cascade do |t|
    t.string "cnes", limit: 7, null: false
    t.string "name", null: false
    t.uuid "snapshot_id", null: false
    t.string "unit_type", limit: 4
    t.index ["snapshot_id", "cnes"], name: "index_cnes_establishments_on_snapshot_id_and_cnes", unique: true
  end

  create_table "cnes_professional_bonds", force: :cascade do |t|
    t.string "cbo_code", limit: 6, null: false
    t.string "cnes", limit: 7, null: false
    t.text "cns"
    t.text "cpf"
    t.string "ine", limit: 10
    t.uuid "snapshot_id", null: false
    t.index ["snapshot_id"], name: "index_cnes_professional_bonds_on_snapshot_id"
  end

  create_table "cnes_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "competence", limit: 6, null: false
    t.datetime "created_at", null: false
    t.string "ibge_code", limit: 7, null: false
    t.datetime "imported_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ibge_code", "competence"], name: "idx_cnes_snapshots_municipality_competence", unique: true
    t.check_constraint "competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text", name: "ck_cnes_snapshots_competence"
    t.check_constraint "ibge_code::text ~ '^[0-9]{7}$'::text", name: "ck_cnes_snapshots_ibge_code"
  end

  create_table "cnes_teams", force: :cascade do |t|
    t.boolean "active", null: false
    t.string "cnes", limit: 7, null: false
    t.string "ine", limit: 10, null: false
    t.string "kind", limit: 4, null: false
    t.string "name"
    t.uuid "snapshot_id", null: false
    t.index ["snapshot_id", "ine"], name: "index_cnes_teams_on_snapshot_id_and_ine", unique: true
  end

  create_table "maintainer_invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.uuid "maintainer_id", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index ["maintainer_id"], name: "index_maintainer_invitations_on_maintainer_id"
    t.index ["token_digest"], name: "index_maintainer_invitations_on_token_digest", unique: true
  end

  create_table "maintainer_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "last_seen_at"
    t.uuid "maintainer_id", null: false
    t.datetime "mfa_verified_at"
    t.integer "totp_attempts", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["maintainer_id"], name: "index_maintainer_sessions_on_maintainer_id"
  end

  create_table "maintainers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email_address", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.uuid "invited_by_id"
    t.bigint "last_otp_step"
    t.datetime "locked_until"
    t.datetime "otp_enabled_at"
    t.jsonb "otp_recovery_codes", default: [], null: false
    t.string "otp_secret"
    t.string "password_digest"
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_maintainers_on_lower_email", unique: true
  end

  create_table "maintenance_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "access", null: false
    t.string "city_slugs", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_used_at"
    t.string "last_used_ip"
    t.uuid "maintainer_id", null: false
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["maintainer_id"], name: "index_maintenance_tokens_on_maintainer_id"
    t.index ["token_digest"], name: "index_maintenance_tokens_on_token_digest", unique: true
    t.check_constraint "access::text = ANY (ARRAY['read'::character varying, 'read_write'::character varying]::text[])", name: "ck_maintenance_tokens_access"
  end

  create_table "operator_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.integer "mfa_failed_attempts", default: 0, null: false
    t.datetime "mfa_verified_at"
    t.uuid "operator_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["operator_id"], name: "index_operator_sessions_on_operator_id"
  end

  create_table "operators", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email_address", null: false
    t.boolean "otp_enabled", default: false, null: false
    t.jsonb "otp_recovery_codes", default: [], null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_operators_on_lower_email", unique: true
  end

  create_table "platform_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "published_at"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_platform_events_on_name"
    t.index ["occurred_at"], name: "idx_platform_events_pending", where: "(published_at IS NULL)"
    t.index ["occurred_at"], name: "index_platform_events_on_occurred_at"
  end

  create_table "signature_provider_checks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_check_at", null: false
    t.boolean "last_check_ok", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["provider"], name: "index_signature_provider_checks_on_provider", unique: true
    t.check_constraint "provider::text = ANY (ARRAY['vidaas'::text, 'birdid'::text, 'safeid'::text, 'neoid'::text, 'remoteid'::text, 'simulated'::text])", name: "ck_signature_provider_checks_provider"
  end

  create_table "sigtap_procedure_cbos", force: :cascade do |t|
    t.string "cbo_code", limit: 6, null: false
    t.string "procedure_code", limit: 10, null: false
    t.uuid "release_id", null: false
    t.index ["release_id", "procedure_code", "cbo_code"], name: "idx_sigtap_procedure_cbos_unique", unique: true
  end

  create_table "sigtap_procedure_cids", force: :cascade do |t|
    t.string "cid_code", limit: 4, null: false
    t.boolean "principal", default: false, null: false
    t.string "procedure_code", limit: 10, null: false
    t.uuid "release_id", null: false
    t.index ["release_id", "procedure_code", "cid_code"], name: "idx_sigtap_procedure_cids_unique", unique: true
  end

  create_table "sigtap_procedure_instruments", force: :cascade do |t|
    t.string "instrument_code", limit: 2, null: false
    t.string "instrument_name", null: false
    t.string "procedure_code", limit: 10, null: false
    t.uuid "release_id", null: false
    t.index ["release_id", "procedure_code", "instrument_code"], name: "idx_sigtap_procedure_instruments_unique", unique: true
  end

  create_table "sigtap_procedures", force: :cascade do |t|
    t.integer "age_max_months"
    t.integer "age_min_months"
    t.string "code", limit: 10, null: false
    t.string "complexity", limit: 1
    t.text "name", null: false
    t.uuid "release_id", null: false
    t.string "sex", limit: 1
    t.index ["release_id", "code"], name: "index_sigtap_procedures_on_release_id_and_code", unique: true
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
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

  create_table "terminology_releases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.datetime "imported_at", null: false
    t.string "imported_by", limit: 80, null: false
    t.string "kind", null: false
    t.string "source_sha256", limit: 64, null: false
    t.string "status", default: "importing", null: false
    t.datetime "updated_at", null: false
    t.string "version", limit: 20, null: false
    t.index ["kind", "status", "version"], name: "idx_terminology_releases_lookup"
    t.index ["kind", "version"], name: "idx_terminology_releases_one_active", unique: true, where: "((status)::text = 'active'::text)"
    t.check_constraint "kind::text <> 'sigtap'::text OR version::text ~ '^[0-9]{6}$'::text", name: "ck_terminology_releases_sigtap_version"
    t.check_constraint "kind::text = ANY (ARRAY['cid10'::text, 'ciap2'::text, 'sigtap'::text])", name: "ck_terminology_releases_kind"
    t.check_constraint "status::text = ANY (ARRAY['importing'::text, 'active'::text, 'superseded'::text, 'failed'::text])", name: "ck_terminology_releases_status"
  end

  create_table "unknown_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "first_seen_at", null: false
    t.integer "hits", default: 1, null: false
    t.datetime "last_seen_at", null: false
    t.string "phone_number_id", null: false
    t.jsonb "sample_change", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["phone_number_id"], name: "index_unknown_channels_on_phone_number_id", unique: true
  end

  add_foreign_key "ciap2_codes", "terminology_releases", column: "release_id"
  add_foreign_key "cid10_codes", "terminology_releases", column: "release_id"
  add_foreign_key "city_analytics_indicators", "cities"
  add_foreign_key "city_channels", "cities"
  add_foreign_key "city_features", "cities"
  add_foreign_key "city_features", "maintainers", column: "changed_by_maintainer_id"
  add_foreign_key "city_grants", "cities"
  add_foreign_key "city_production_summaries", "cities"
  add_foreign_key "cnes_establishments", "cnes_snapshots", column: "snapshot_id", on_delete: :cascade
  add_foreign_key "cnes_professional_bonds", "cnes_snapshots", column: "snapshot_id", on_delete: :cascade
  add_foreign_key "cnes_teams", "cnes_snapshots", column: "snapshot_id", on_delete: :cascade
  add_foreign_key "operator_sessions", "operators"
  add_foreign_key "sigtap_procedure_cbos", "terminology_releases", column: "release_id"
  add_foreign_key "sigtap_procedure_cids", "terminology_releases", column: "release_id"
  add_foreign_key "sigtap_procedure_instruments", "terminology_releases", column: "release_id"
  add_foreign_key "sigtap_procedures", "terminology_releases", column: "release_id"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
