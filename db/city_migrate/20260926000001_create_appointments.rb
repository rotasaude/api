# Chamada, retorno e agendamento (spec 2026-09-25-citizen-appointments §3; ADR 0019).
# Papel health_professional; attendances ganha estados waiting/in_care/closed,
# chamada, desfecho return e origem triagem-OU-horário; pedido e horário novos.
# Triggers vêm de db/city_triggers.sql (mesma fonte do load_city_schema).
class CreateAppointments < ActiveRecord::Migration[8.1]
  ROLES_BEFORE = %w[citizen_verifier municipal_admin protocol_author protocol_publisher protocol_reviewer viewer].freeze
  ROLES_AFTER = %w[citizen_verifier health_professional municipal_admin protocol_author protocol_publisher
                   protocol_reviewer viewer].freeze

  def up
    replace_roles_check(ROLES_AFTER)

    %w[ck_attendances_status ck_attendances_closing ck_attendances_outcome ck_attendances_referral].each do |name|
      remove_check_constraint :attendances, name: name
    end
    execute "UPDATE attendances SET status = 'waiting' WHERE status = 'open'"
    change_column_default :attendances, :status, from: "open", to: "waiting"
    change_column_null :attendances, :triage_id, true
    add_reference :attendances, :called_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
    add_column :attendances, :called_at, :datetime

    create_table :appointment_requests, id: :uuid do |t|
      t.references :origin_attendance, type: :uuid, null: false, foreign_key: { to_table: :attendances },
                                       index: { unique: true }
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.references :root_triage, type: :uuid, null: false, foreign_key: { to_table: :triages }, index: true
      t.references :origin_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: true
      t.references :target_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: true
      t.string :kind, null: false
      t.text :note
      t.string :status, null: false, default: "open"
      t.string :reopened_reason
      t.string :closed_reason
      t.text :dismiss_reason
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.datetime :closed_at
      t.timestamps
    end
    add_check_constraint :appointment_requests, "kind::text = ANY (ARRAY['return', 'referral']::text[])",
                         name: "ck_appointment_requests_kind"
    add_check_constraint :appointment_requests, "kind::text <> 'return'::text OR origin_unit_id = target_unit_id",
                         name: "ck_appointment_requests_return_same_unit"
    add_check_constraint :appointment_requests, "status::text = ANY (ARRAY['open', 'scheduled', 'closed']::text[])",
                         name: "ck_appointment_requests_status"
    add_check_constraint :appointment_requests,
                         "reopened_reason IS NULL OR reopened_reason::text = ANY (ARRAY['expired', 'no_show']::text[])",
                         name: "ck_appointment_requests_reopened_reason"
    add_check_constraint :appointment_requests,
                         "(status::text <> 'closed'::text AND closed_reason IS NULL AND closed_at IS NULL) OR " \
                         "(status::text = 'closed'::text AND closed_reason IS NOT NULL AND closed_at IS NOT NULL)",
                         name: "ck_appointment_requests_closing"
    add_check_constraint :appointment_requests,
                         "closed_reason IS NULL OR closed_reason::text = ANY (ARRAY['fulfilled', 'citizen_cancelled', 'dismissed']::text[])",
                         name: "ck_appointment_requests_closed_reason"
    add_check_constraint :appointment_requests,
                         "(closed_reason IS DISTINCT FROM 'dismissed' AND dismiss_reason IS NULL) OR " \
                         "(closed_reason = 'dismissed' AND dismiss_reason IS NOT NULL AND length(btrim(dismiss_reason)) >= 10)",
                         name: "ck_appointment_requests_dismiss_reason"

    create_table :appointments, id: :uuid do |t|
      t.references :request, type: :uuid, null: false, foreign_key: { to_table: :appointment_requests }, index: true
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :scheduled_at, null: false
      t.references :scheduled_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: true
      t.datetime :confirmation_deadline_at
      t.string :status, null: false
      t.datetime :confirmed_at
      t.text :cancel_reason
      t.datetime :ended_at
      t.timestamps
    end
    add_index :appointments, :request_id, unique: true, where: "status IN ('scheduled', 'confirmed')",
              name: "idx_appointments_one_live_per_request"
    add_index :appointments, %i[health_unit_id scheduled_at], name: "idx_appointments_unit_time"
    add_check_constraint :appointments,
                         "status::text = ANY (ARRAY['scheduled', 'confirmed', 'checked_in', 'cancelled_by_citizen', 'expired', 'no_show']::text[])",
                         name: "ck_appointments_status"
    add_check_constraint :appointments, "status::text <> 'scheduled'::text OR confirmation_deadline_at IS NOT NULL",
                         name: "ck_appointments_deadline"
    add_check_constraint :appointments,
                         "(status::text <> 'cancelled_by_citizen'::text AND cancel_reason IS NULL) OR " \
                         "(status::text = 'cancelled_by_citizen'::text AND cancel_reason IS NOT NULL AND length(btrim(cancel_reason)) >= 10)",
                         name: "ck_appointments_cancel_reason"
    add_check_constraint :appointments,
                         "(status::text = ANY (ARRAY['scheduled', 'confirmed']::text[])) = (ended_at IS NULL)",
                         name: "ck_appointments_ended"

    add_reference :attendances, :appointment, type: :uuid, foreign_key: true, index: { unique: true }
    add_check_constraint :attendances, "status::text = ANY (ARRAY['waiting', 'in_care', 'closed']::text[])",
                         name: "ck_attendances_status"
    add_check_constraint :attendances,
                         "outcome IS NULL OR outcome::text = ANY (ARRAY['discharged', 'referred', 'return', 'left']::text[])",
                         name: "ck_attendances_outcome"
    add_check_constraint :attendances, "(called_by_user_id IS NULL) = (called_at IS NULL)",
                         name: "ck_attendances_calling"
    add_check_constraint :attendances,
                         "(status::text = 'waiting'::text AND called_at IS NULL AND outcome IS NULL AND closed_by_user_id IS NULL " \
                         "AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(status::text = 'in_care'::text AND called_at IS NOT NULL AND outcome IS NULL AND closed_by_user_id IS NULL " \
                         "AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(status::text = 'closed'::text AND outcome IS NOT NULL AND closed_by_user_id IS NOT NULL AND closed_at IS NOT NULL)",
                         name: "ck_attendances_closing"
    add_check_constraint :attendances,
                         "((outcome IS NULL OR outcome::text = ANY (ARRAY['discharged', 'left']::text[])) " \
                         "AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(outcome = 'referred' AND (referral_unit_id IS NOT NULL OR " \
                         "(referral_note IS NOT NULL AND length(btrim(referral_note)) > 0))) OR " \
                         "(outcome = 'return' AND referral_unit_id IS NULL)",
                         name: "ck_attendances_referral"
    add_check_constraint :attendances, "(triage_id IS NULL) <> (appointment_id IS NULL)",
                         name: "ck_attendances_origin"

    add_reference :citizen_verification_codes, :appointment, type: :uuid, foreign_key: true, index: true
    remove_check_constraint :citizen_verification_codes, name: "ck_citizen_verification_codes_purpose_triage"
    add_check_constraint :citizen_verification_codes,
                         "(purpose::text = 'verification'::text AND triage_id IS NULL AND appointment_id IS NULL) OR " \
                         "(purpose::text = 'check_in'::text AND (triage_id IS NULL) <> (appointment_id IS NULL))",
                         name: "ck_citizen_verification_codes_purpose_target"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "attendances e pedidos só aceitam acréscimo; não há volta segura"
  end

  private

  # Mesma forma de 20260924000001: ANY (ARRAY[...]::text[]) sobrevive ao round-trip.
  def replace_roles_check(roles)
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{roles.map { |r| "'#{r}'" }.join(', ')}]::text[])",
                         name: "ck_memberships_role"
  end
end
