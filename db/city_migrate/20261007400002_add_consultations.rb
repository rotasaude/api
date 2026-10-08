# Módulo 19 (ADR 0031; spec 2026-10-07 §4–§5): a consulta SOAP (texto
# cifrado, sinais vitais com os limites do módulo 18), os itens estruturados
# (só acréscimo; os do rascunho ficam em draft_items até a finalização), os
# adendos e as aberturas justificadas. As FKs dos eventos de problema são
# DEFERRABLE (a ordem de escrita na finalização é livre; o commit confere).
# Triggers em db/city_triggers.sql.
class AddConsultations < ActiveRecord::Migration[8.1]
  VITALS = {
    "ck_consultations_bp" => "(systolic IS NULL AND diastolic IS NULL) OR (systolic IS NOT NULL AND diastolic IS NOT NULL AND diastolic < systolic)",
    "ck_consultations_systolic" => "systolic IS NULL OR systolic BETWEEN 50 AND 300",
    "ck_consultations_diastolic" => "diastolic IS NULL OR diastolic BETWEEN 20 AND 200",
    "ck_consultations_heart_rate" => "heart_rate IS NULL OR heart_rate BETWEEN 20 AND 250",
    "ck_consultations_respiratory_rate" => "respiratory_rate IS NULL OR respiratory_rate BETWEEN 4 AND 80",
    "ck_consultations_temperature" => "temperature_c IS NULL OR temperature_c BETWEEN 30 AND 45",
    "ck_consultations_spo2" => "spo2 IS NULL OR spo2 BETWEEN 50 AND 100",
    "ck_consultations_glucose" => "(capillary_glucose IS NULL AND glucose_moment IS NULL) OR (capillary_glucose BETWEEN 10 AND 800 AND glucose_moment::text = ANY (ARRAY['fasting'::text, 'postprandial'::text, 'random'::text]))",
    "ck_consultations_weight" => "weight_kg IS NULL OR weight_kg BETWEEN 0.5 AND 400",
    "ck_consultations_height" => "height_cm IS NULL OR height_cm BETWEEN 30 AND 250",
    "ck_consultations_pain_score" => "pain_score IS NULL OR pain_score BETWEEN 0 AND 10"
  }.freeze
  CONDUCT_CODES = "ARRAY[1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14]".freeze

  def up
    create_table :consultations, id: :uuid do |t|
      t.uuid :attendance_id, null: false
      t.uuid :patient_id, null: false
      t.uuid :author_user_id, null: false
      t.uuid :professional_link_id, null: false
      t.string :cbo_code, null: false
      t.string :status, null: false, default: "draft"
      t.text :subjective
      t.text :objective
      t.text :assessment
      t.text :plan
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
      t.integer :care_type
      t.jsonb :draft_items, null: false, default: {}
      t.datetime :started_at, null: false
      t.datetime :finalized_at
      t.timestamps
    end
    add_index :consultations, :attendance_id, unique: true
    add_index :consultations, :patient_id
    add_index :consultations, :author_user_id
    add_index :consultations, :professional_link_id
    add_foreign_key :consultations, :attendances
    add_foreign_key :consultations, :patients
    add_foreign_key :consultations, :users, column: :author_user_id
    add_foreign_key :consultations, :professional_links
    {
      "ck_consultations_status" => "status::text = ANY (ARRAY['draft'::text, 'finalized'::text])",
      "ck_consultations_finalization" => "(status::text = 'finalized'::text) = (finalized_at IS NOT NULL)",
      "ck_consultations_draft_items" => "jsonb_typeof(draft_items) = 'object'::text AND (status::text = 'draft'::text OR draft_items = '{}'::jsonb)",
      "ck_consultations_care_type" => "care_type IS NULL OR care_type = ANY (ARRAY[1, 2, 5, 6])",
      "ck_consultations_finalized_care_type" => "status::text = 'draft'::text OR care_type IS NOT NULL",
      "ck_consultations_cbo_code" => "cbo_code::text ~ '^[0-9A-Z]{6}$'::text"
    }.merge(VITALS).each { |name, expression| add_check_constraint :consultations, expression, name: name }

    create_table :clinical_record_openings, id: :uuid do |t|
      t.uuid :patient_id, null: false
      t.uuid :user_id, null: false
      t.string :reason_code, null: false
      t.text :reason_note
      t.datetime :created_at, null: false
      t.datetime :expires_at, null: false
    end
    add_index :clinical_record_openings, %i[user_id patient_id expires_at], name: "idx_clinical_record_openings_valid"
    add_index :clinical_record_openings, :patient_id
    add_index :clinical_record_openings, :created_at
    add_foreign_key :clinical_record_openings, :patients
    add_foreign_key :clinical_record_openings, :users
    {
      "ck_clinical_record_openings_reason" => "reason_code::text = ANY (ARRAY['case_review'::text, 'active_search'::text, 'continuity_of_care'::text, 'other'::text])",
      "ck_clinical_record_openings_note" => "(reason_code::text = 'other'::text) = (reason_note IS NOT NULL)",
      "ck_clinical_record_openings_expiry" => "expires_at > created_at"
    }.each { |name, expression| add_check_constraint :clinical_record_openings, expression, name: name }

    create_table :consultation_addenda, id: :uuid do |t|
      t.uuid :consultation_id, null: false
      t.uuid :author_user_id, null: false
      t.text :text, null: false
      t.text :reason, null: false
      # `changes` (o nome do contrato da API) colide com ActiveModel::Dirty#changes
      # (DangerousAttributeError); a coluna é item_changes, a chave JSON segue `changes`.
      t.jsonb :item_changes, null: false, default: {}
      t.uuid :opening_id
      t.datetime :created_at, null: false
    end
    add_index :consultation_addenda, :consultation_id
    add_index :consultation_addenda, :author_user_id
    add_index :consultation_addenda, :opening_id
    add_foreign_key :consultation_addenda, :consultations
    add_foreign_key :consultation_addenda, :users, column: :author_user_id
    add_foreign_key :consultation_addenda, :clinical_record_openings, column: :opening_id
    add_check_constraint :consultation_addenda, "length(btrim(reason)) BETWEEN 10 AND 500", name: "ck_consultation_addenda_reason"
    add_check_constraint :consultation_addenda, "jsonb_typeof(item_changes) = 'object'::text",
                         name: "ck_consultation_addenda_item_changes"

    create_table :consultation_problems, id: :uuid do |t|
      t.uuid :consultation_id, null: false
      t.uuid :addendum_id
      t.uuid :patient_problem_id, null: false
      t.string :action, null: false
      t.string :terminology, null: false
      t.string :code, limit: 4, null: false
      t.uuid :terminology_release_id, null: false
      t.string :status_after, null: false
      t.date :onset_on
      t.string :onset_precision
      t.date :resolved_on
      t.datetime :created_at, null: false
    end
    add_index :consultation_problems, :consultation_id
    add_index :consultation_problems, :addendum_id
    add_index :consultation_problems, :patient_problem_id
    add_foreign_key :consultation_problems, :consultations
    add_foreign_key :consultation_problems, :consultation_addenda, column: :addendum_id
    add_foreign_key :consultation_problems, :patient_problems
    {
      "ck_consultation_problems_action" => "action::text = ANY (ARRAY['evaluate'::text, 'add'::text, 'resolve'::text, 'correct_onset'::text])",
      "ck_consultation_problems_terminology" => "terminology::text = ANY (ARRAY['ciap2'::text, 'cid10'::text])",
      "ck_consultation_problems_status" => "status_after::text = ANY (ARRAY['active'::text, 'resolved'::text])"
    }.each { |name, expression| add_check_constraint :consultation_problems, expression, name: name }

    create_table :consultation_conducts, id: :uuid do |t|
      t.uuid :consultation_id, null: false
      t.uuid :addendum_id
      t.integer :code, null: false
      t.string :action, null: false, default: "add"
      t.datetime :created_at, null: false
    end
    add_index :consultation_conducts, :consultation_id
    add_index :consultation_conducts, :addendum_id
    add_foreign_key :consultation_conducts, :consultations
    add_foreign_key :consultation_conducts, :consultation_addenda, column: :addendum_id
    add_check_constraint :consultation_conducts, "code = ANY (#{CONDUCT_CODES})", name: "ck_consultation_conducts_code"
    add_check_constraint :consultation_conducts, "action::text = ANY (ARRAY['add'::text, 'remove'::text])",
                         name: "ck_consultation_conducts_action"
    add_check_constraint :consultation_conducts, "action::text = 'add'::text OR addendum_id IS NOT NULL",
                         name: "ck_consultation_conducts_removal"

    create_table :consultation_exam_requests, id: :uuid do |t|
      t.uuid :consultation_id, null: false
      t.uuid :addendum_id
      t.string :sigtap_code, limit: 10, null: false
      t.string :sigtap_competence, limit: 6, null: false
      t.string :cid10_justification, limit: 4
      t.string :status, null: false, default: "requested"
      t.datetime :created_at, null: false
    end
    add_index :consultation_exam_requests, :consultation_id
    add_index :consultation_exam_requests, :addendum_id
    add_foreign_key :consultation_exam_requests, :consultations
    add_foreign_key :consultation_exam_requests, :consultation_addenda, column: :addendum_id
    {
      "ck_consultation_exam_requests_sigtap" => "sigtap_code::text ~ '^02[0-9]{8}$'::text",
      "ck_consultation_exam_requests_competence" => "sigtap_competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text",
      "ck_consultation_exam_requests_cid10" => "cid10_justification IS NULL OR cid10_justification::text ~ '^[A-Z][0-9]{2}[0-9X]?$'::text",
      "ck_consultation_exam_requests_status" => "status::text = ANY (ARRAY['requested'::text, 'cancelled'::text])",
      "ck_consultation_exam_requests_cancel" => "status::text = 'requested'::text OR addendum_id IS NOT NULL"
    }.each { |name, expression| add_check_constraint :consultation_exam_requests, expression, name: name }

    add_foreign_key :patient_problem_events, :consultations, deferrable: :deferred
    add_foreign_key :patient_problem_events, :consultation_addenda, column: :addendum_id, deferrable: :deferred

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
