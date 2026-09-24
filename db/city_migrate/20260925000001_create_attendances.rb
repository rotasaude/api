# Check-in na unidade e desfecho do atendimento (spec 2026-09-24-citizen-
# attendance-check-in-design §3; ADR 0018). Aditiva. attendances só aceita
# acréscimo, exceto encerrar uma vez — trigger em db/city_triggers.sql.
class CreateAttendances < ActiveRecord::Migration[8.1]
  def up
    create_table :health_units, id: :uuid do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :health_units, "lower((name)::text)", unique: true, name: "idx_health_units_name_ci"
    add_check_constraint :health_units, "kind::text = ANY (ARRAY['ubs', 'upa', 'hospital', 'other']::text[])",
                         name: "ck_health_units_kind"

    add_column :citizen_verification_codes, :purpose, :string, null: false, default: "verification"
    add_reference :citizen_verification_codes, :triage, type: :uuid, foreign_key: true, index: true
    add_check_constraint :citizen_verification_codes,
                         "purpose::text = ANY (ARRAY['verification', 'check_in']::text[])",
                         name: "ck_citizen_verification_codes_purpose"
    add_check_constraint :citizen_verification_codes,
                         "(purpose::text = 'check_in'::text) = (triage_id IS NOT NULL)",
                         name: "ck_citizen_verification_codes_purpose_triage"

    create_table :attendances, id: :uuid do |t|
      t.references :triage, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: true
      t.references :checked_in_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :checked_in_at, null: false
      t.string :check_in_method, null: false
      t.text :exception_reason
      t.string :status, null: false, default: "open"
      t.string :outcome
      t.references :referral_unit, type: :uuid, foreign_key: { to_table: :health_units }, index: true
      t.text :referral_note
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.datetime :closed_at
      t.datetime :created_at, null: false
    end
    add_check_constraint :attendances, "check_in_method::text = ANY (ARRAY['code', 'cpf_exception']::text[])",
                         name: "ck_attendances_method"
    add_check_constraint :attendances,
                         "(check_in_method::text = 'code'::text AND exception_reason IS NULL) OR " \
                         "(check_in_method::text = 'cpf_exception'::text AND exception_reason IS NOT NULL " \
                         "AND length(btrim(exception_reason)) >= 10)",
                         name: "ck_attendances_exception_reason"
    add_check_constraint :attendances, "status::text = ANY (ARRAY['open', 'closed']::text[])",
                         name: "ck_attendances_status"
    add_check_constraint :attendances,
                         "(status::text = 'open'::text AND outcome IS NULL AND closed_by_user_id IS NULL " \
                         "AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(status::text = 'closed'::text AND outcome IS NOT NULL AND closed_by_user_id IS NOT NULL " \
                         "AND closed_at IS NOT NULL)",
                         name: "ck_attendances_closing"
    add_check_constraint :attendances,
                         "outcome IS NULL OR outcome::text = ANY (ARRAY['discharged', 'referred', 'left']::text[])",
                         name: "ck_attendances_outcome"
    add_check_constraint :attendances,
                         "(outcome IS DISTINCT FROM 'referred' AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(outcome = 'referred' AND (referral_unit_id IS NOT NULL OR " \
                         "(referral_note IS NOT NULL AND length(btrim(referral_note)) > 0)))",
                         name: "ck_attendances_referral"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS attendances_guard ON attendances"
    execute "DROP TRIGGER IF EXISTS attendances_append_only_truncate ON attendances"
    execute "DROP FUNCTION IF EXISTS rota_attendance_guard()"
    drop_table :attendances
    remove_check_constraint :citizen_verification_codes, name: "ck_citizen_verification_codes_purpose_triage"
    remove_check_constraint :citizen_verification_codes, name: "ck_citizen_verification_codes_purpose"
    remove_reference :citizen_verification_codes, :triage, foreign_key: true, index: true
    remove_column :citizen_verification_codes, :purpose
    drop_table :health_units
  end
end
