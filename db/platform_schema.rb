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

ActiveRecord::Schema[8.1].define(version: 2026_09_17_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "cities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "database_url", null: false
    t.text "encryption_key", null: false
    t.string "name", null: false
    t.string "schema_version"
    t.string "slug", null: false
    t.string "status", default: "provisioning", null: false
    t.string "uf", limit: 2
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_cities_on_slug", unique: true
    t.check_constraint "slug::text ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'::text AND length(slug::text) >= 2 AND length(slug::text) <= 63", name: "ck_cities_slug_is_dns_label"
    t.check_constraint "status::text = ANY (ARRAY['provisioning'::character varying, 'active'::character varying, 'suspended'::character varying, 'archived'::character varying]::text[])", name: "ck_cities_status"
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
    t.datetime "locked_until"
    t.datetime "otp_enabled_at"
    t.jsonb "otp_recovery_codes", default: [], null: false
    t.string "otp_secret"
    t.string "password_digest"
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_maintainers_on_lower_email", unique: true
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

  add_foreign_key "city_channels", "cities"
  add_foreign_key "city_grants", "cities"
  add_foreign_key "operator_sessions", "operators"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
