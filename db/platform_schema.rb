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

ActiveRecord::Schema[8.1].define(version: 2026_09_12_000001) do
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
end
