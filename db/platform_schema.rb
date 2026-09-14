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

ActiveRecord::Schema[8.1].define(version: 2026_09_13_000001) do
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

  create_table "operator_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
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
  add_foreign_key "operator_sessions", "operators"
end
