# Profissionais (ADR 0021; spec 2026-09-27-module-10-professionals §3): perfil
# 1:1 com o usuário, vínculo com unidade e CBO, turnos com instantes. Vínculo e
# turno só aceitam acréscimo (triggers em db/city_triggers.sql, a mesma fonte
# do load_city_schema). Timestamps são `timestamp` sem fuso em UTC, como o
# resto do banco — por isso a EXCLUDE usa tsrange, não tstzrange.
class CreateProfessionals < ActiveRecord::Migration[8.1]
  def up
    enable_extension "btree_gist"

    create_table :professionals, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :professional_name, null: false
      t.string :council, null: false
      t.string :council_state, null: false
      t.string :registration_number, null: false
      t.string :cns, null: false
      t.string :phone
      t.string :contact_email
      t.timestamps
    end
    add_index :professionals, %i[council council_state registration_number], unique: true,
              name: "idx_professionals_registration"
    add_index :professionals, :cns, unique: true, name: "idx_professionals_cns"
    add_check_constraint :professionals, "length(btrim(professional_name::text)) > 0", name: "ck_professionals_name"
    add_check_constraint :professionals, "council_state::text ~ '^[A-Z]{2}$'::text", name: "ck_professionals_council_state"
    add_check_constraint :professionals, "registration_number::text ~ '^[0-9]{1,10}$'::text",
                         name: "ck_professionals_registration_number"

    create_table :professional_links, id: :uuid do |t|
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: true
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: true
      t.string :cbo_code, null: false
      t.datetime :started_at, null: false
      t.references :started_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :ended_at
      t.references :ended_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.datetime :created_at, null: false
    end
    add_index :professional_links, %i[professional_id health_unit_id cbo_code], unique: true,
              where: "(ended_at IS NULL)", name: "idx_professional_links_one_active"
    add_check_constraint :professional_links, "cbo_code::text ~ '^[0-9]{6}$'::text", name: "ck_professional_links_cbo_code"
    add_check_constraint :professional_links, "(ended_at IS NULL) = (ended_by_user_id IS NULL)",
                         name: "ck_professional_links_ending"
    add_check_constraint :professional_links, "ended_at IS NULL OR ended_at >= started_at",
                         name: "ck_professional_links_order"

    create_table :professional_shifts, id: :uuid do |t|
      t.references :professional_link, type: :uuid, null: false, foreign_key: true, index: true
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :cancelled_at
      t.references :cancelled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.string :cancel_reason
      t.datetime :created_at, null: false
    end
    add_check_constraint :professional_shifts,
                         "ends_at > starts_at AND (ends_at - starts_at) <= '24:00:00'::interval",
                         name: "ck_professional_shifts_window"
    add_check_constraint :professional_shifts,
                         "(cancelled_at IS NULL AND cancelled_by_user_id IS NULL AND cancel_reason IS NULL) OR " \
                         "(cancelled_at IS NOT NULL AND cancelled_by_user_id IS NOT NULL AND cancel_reason IS NOT NULL " \
                         "AND length(btrim(cancel_reason::text)) > 0)",
                         name: "ck_professional_shifts_cancelling"
    add_exclusion_constraint :professional_shifts, "professional_id WITH =, tsrange(starts_at, ends_at) WITH &&",
                             using: :gist, where: "(cancelled_at IS NULL)", name: "excl_professional_shifts_overlap"
    add_index :professional_shifts, %i[professional_link_id starts_at], name: "idx_professional_shifts_link_start"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    drop_table :professional_shifts
    drop_table :professional_links
    drop_table :professionals
    execute "DROP FUNCTION IF EXISTS rota_professional_link_guard()"
    execute "DROP FUNCTION IF EXISTS rota_professional_shift_guard()"
  end
end
