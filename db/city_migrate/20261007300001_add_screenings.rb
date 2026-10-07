# Módulo 18 (ADR 0030; spec 2026-10-07 §3–§5): escuta inicial com revisões só
# de acréscimo, escopo por unidade, desfechos de escuta e a exceção na trava
# do módulo 13, pedido de agendamento com origem na escuta e as fichas que não
# puderam ser geradas. Triggers em db/city_triggers.sql.
class AddScreenings < ActiveRecord::Migration[8.1]
  SCREENING_OUTCOMES = "'scheduled_from_screening'::text, 'oriented'::text".freeze

  def up
    add_column :health_units, :screening_scope, :string, null: false, default: "walk_in"
    add_check_constraint :health_units, "screening_scope::text = ANY (ARRAY['walk_in'::text, 'all'::text])",
                         name: "ck_health_units_screening_scope"

    create_table :screenings, id: :uuid do |t|
      t.uuid :attendance_id, null: false
      t.string :status, null: false, default: "in_progress"
      t.uuid :started_by_user_id, null: false
      t.uuid :professional_link_id, null: false
      t.string :cbo_code, null: false
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.uuid :current_revision_id
      t.string :destination
      t.text :orientation_note
      t.uuid :appointment_request_id
      t.timestamps
    end
    add_index :screenings, :attendance_id, unique: true
    add_index :screenings, :started_by_user_id
    add_index :screenings, :professional_link_id
    add_index :screenings, :appointment_request_id
    add_index :screenings, :status
    add_foreign_key :screenings, :attendances
    add_foreign_key :screenings, :users, column: :started_by_user_id
    add_foreign_key :screenings, :professional_links
    add_foreign_key :screenings, :appointment_requests
    add_check_constraint :screenings, "status::text = ANY (ARRAY['in_progress'::text, 'completed'::text, 'abandoned'::text])",
                         name: "ck_screenings_status"
    add_check_constraint :screenings,
                         "destination IS NULL OR destination::text = ANY (ARRAY['same_day'::text, 'schedule'::text, 'oriented'::text, 'referred'::text])",
                         name: "ck_screenings_destination"
    add_check_constraint :screenings,
                         "(status::text = 'completed'::text) = (completed_at IS NOT NULL AND destination IS NOT NULL AND current_revision_id IS NOT NULL)",
                         name: "ck_screenings_completion"
    add_check_constraint :screenings,
                         "(destination IS DISTINCT FROM 'oriented' AND orientation_note IS NULL) OR " \
                         "(destination IS NOT DISTINCT FROM 'oriented' AND orientation_note IS NOT NULL AND length(btrim(orientation_note)) BETWEEN 1 AND 500)",
                         name: "ck_screenings_orientation"
    add_check_constraint :screenings, "(destination IS NOT DISTINCT FROM 'schedule') = (appointment_request_id IS NOT NULL)",
                         name: "ck_screenings_schedule"
    add_check_constraint :screenings, "cbo_code::text ~ '^[0-9]{6}$'::text", name: "ck_screenings_cbo_code"

    create_table :screening_revisions, id: :uuid do |t|
      t.uuid :screening_id, null: false
      t.uuid :by_user_id, null: false
      t.datetime :created_at, null: false
      t.string :ciap2_code, limit: 3, null: false
      t.uuid :ciap2_release_id, null: false
      t.text :complaint_note
      t.integer :systolic
      t.integer :diastolic
      t.integer :heart_rate
      t.integer :respiratory_rate
      t.decimal :temperature_c, precision: 3, scale: 1
      t.integer :spo2
      t.integer :capillary_glucose
      t.string :glucose_moment
      t.decimal :weight_kg, precision: 5, scale: 2
      t.integer :height_cm
      t.integer :pain_score
      t.string :suggested_color
      t.string :final_color, null: false
      t.text :color_change_reason
      t.uuid :rule_protocol_definition_id
      t.integer :matched_rules, array: true, null: false, default: []
    end
    add_index :screening_revisions, :screening_id
    add_index :screening_revisions, :by_user_id
    add_foreign_key :screening_revisions, :screenings
    add_foreign_key :screening_revisions, :users, column: :by_user_id
    add_foreign_key :screening_revisions, :protocol_definitions, column: :rule_protocol_definition_id
    add_foreign_key :screenings, :screening_revisions, column: :current_revision_id
    colors = "ARRAY['red'::text, 'yellow'::text, 'green'::text, 'blue'::text]"
    {
      "ck_screening_revisions_ciap2" => "ciap2_code::text ~ '^[A-Z][0-9]{2}$'::text",
      "ck_screening_revisions_complaint_note" => "complaint_note IS NULL OR length(complaint_note) <= 500",
      "ck_screening_revisions_bp" => "(systolic IS NULL AND diastolic IS NULL) OR (systolic IS NOT NULL AND diastolic IS NOT NULL AND diastolic < systolic)",
      "ck_screening_revisions_systolic" => "systolic IS NULL OR systolic BETWEEN 50 AND 300",
      "ck_screening_revisions_diastolic" => "diastolic IS NULL OR diastolic BETWEEN 20 AND 200",
      "ck_screening_revisions_heart_rate" => "heart_rate IS NULL OR heart_rate BETWEEN 20 AND 250",
      "ck_screening_revisions_respiratory_rate" => "respiratory_rate IS NULL OR respiratory_rate BETWEEN 4 AND 80",
      "ck_screening_revisions_temperature" => "temperature_c IS NULL OR temperature_c BETWEEN 30 AND 45",
      "ck_screening_revisions_spo2" => "spo2 IS NULL OR spo2 BETWEEN 50 AND 100",
      "ck_screening_revisions_glucose" => "(capillary_glucose IS NULL AND glucose_moment IS NULL) OR (capillary_glucose IS NOT NULL AND glucose_moment IS NOT NULL AND capillary_glucose BETWEEN 10 AND 800 AND glucose_moment::text = ANY (ARRAY['fasting'::text, 'postprandial'::text, 'random'::text]))",
      "ck_screening_revisions_weight" => "weight_kg IS NULL OR weight_kg BETWEEN 0.5 AND 400",
      "ck_screening_revisions_height" => "height_cm IS NULL OR height_cm BETWEEN 30 AND 250",
      "ck_screening_revisions_pain_score" => "pain_score IS NULL OR pain_score BETWEEN 0 AND 10",
      "ck_screening_revisions_suggested_color" => "suggested_color IS NULL OR suggested_color::text = ANY (#{colors})",
      "ck_screening_revisions_final_color" => "final_color::text = ANY (#{colors})",
      "ck_screening_revisions_color_change" => "suggested_color IS NULL OR final_color::text = suggested_color::text OR color_change_reason IS NOT NULL",
      "ck_screening_revisions_color_change_reason" => "color_change_reason IS NULL OR length(btrim(color_change_reason)) BETWEEN 10 AND 500"
    }.each { |name, expression| add_check_constraint :screening_revisions, expression, name: name }

    # Desfechos de escuta e a exceção na trava (spec §4).
    remove_check_constraint :attendances, name: "ck_attendances_outcome"
    add_check_constraint :attendances,
                         "outcome IS NULL OR outcome::text = ANY (ARRAY['discharged'::text, 'referred'::text, 'return'::text, 'left'::text, #{SCREENING_OUTCOMES}])",
                         name: "ck_attendances_outcome"
    remove_check_constraint :attendances, name: "ck_attendances_referral"
    add_check_constraint :attendances,
                         "((outcome IS NULL OR outcome::text = ANY (ARRAY['discharged'::text, 'left'::text, #{SCREENING_OUTCOMES}])) " \
                         "AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(outcome = 'referred' AND (referral_unit_id IS NOT NULL OR (referral_note IS NOT NULL AND length(btrim(referral_note)) > 0))) OR " \
                         "(outcome = 'return' AND referral_unit_id IS NULL)",
                         name: "ck_attendances_referral"
    remove_check_constraint :attendances, name: "ck_attendances_closing"
    add_check_constraint :attendances,
                         "(status::text = 'waiting'::text AND called_at IS NULL AND outcome IS NULL AND closed_by_user_id IS NULL AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(status::text = 'in_care'::text AND called_at IS NOT NULL AND outcome IS NULL AND closed_by_user_id IS NULL AND closed_at IS NULL AND referral_unit_id IS NULL AND referral_note IS NULL) OR " \
                         "(status::text = 'closed'::text AND outcome IS NOT NULL AND closed_by_user_id IS NOT NULL AND closed_at IS NOT NULL " \
                         "AND (called_at IS NOT NULL OR outcome::text = ANY (ARRAY['left'::text, 'referred'::text, #{SCREENING_OUTCOMES}])) " \
                         "AND (called_at IS NULL OR outcome::text <> ALL (ARRAY[#{SCREENING_OUTCOMES}])))",
                         name: "ck_attendances_closing"

    # Pedido com origem na escuta (ADR 0029 + 0030).
    add_column :appointment_requests, :origin_screening_id, :uuid
    add_foreign_key :appointment_requests, :screenings, column: :origin_screening_id
    add_index :appointment_requests, :origin_screening_id, unique: true,
                                                           where: "(closed_reason)::text IS DISTINCT FROM 'moved'::text"
    remove_check_constraint :appointment_requests, name: "ck_appointment_requests_kind"
    add_check_constraint :appointment_requests,
                         "kind::text = ANY (ARRAY['return'::text, 'referral'::text, 'triage'::text, 'screening'::text])",
                         name: "ck_appointment_requests_kind"
    add_check_constraint :appointment_requests, "(kind::text = 'screening'::text) = (origin_screening_id IS NOT NULL)",
                         name: "ck_appointment_requests_screening_kind"
    add_check_constraint :appointment_requests, "origin_screening_id IS NULL OR origin_attendance_id IS NOT NULL",
                         name: "ck_appointment_requests_screening_origin"

    # Fichas que não puderam ser geradas por falta de identificação (spec §5).
    create_table :ledi_generation_failures, id: :uuid do |t|
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.jsonb :reason_codes, null: false, default: []
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :ledi_generation_failures, %i[source_type source_id], unique: true, where: "(resolved_at IS NULL)",
                                                                     name: "idx_ledi_generation_failures_open"
    add_index :ledi_generation_failures, :created_at
    add_check_constraint :ledi_generation_failures,
                         "jsonb_typeof(reason_codes) = 'array'::text AND jsonb_array_length(reason_codes) > 0",
                         name: "ck_ledi_generation_failures_reason_codes"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
