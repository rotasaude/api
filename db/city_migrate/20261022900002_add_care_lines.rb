# Módulo 23 (ADR 0040): linhas de cuidado. Linhas da cidade (adotadas do
# catálogo-base ou próprias), inscrições (a saída muda uma vez; nada se
# apaga), sugestões (decididas congelam; a exclusão LGPD apaga), contatos de
# busca ativa (só acréscimo, nota cifrada) e condições declaradas pelo
# cidadão (só acréscimo; retirar grava withdrawn_at; cifradas; a exclusão
# apaga). Triggers em db/city_triggers.sql. Irreversível.
class AddCareLines < ActiveRecord::Migration[8.1]
  def up
    create_table :care_lines, id: :uuid do |t|
      t.string :source, null: false
      t.string :template_key
      t.integer :template_version
      t.string :indicator, limit: 2
      t.string :name, limit: 120, null: false
      t.jsonb :eligibility, null: false
      t.jsonb :practices, null: false
      t.string :declared_condition
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :care_lines, :template_key, unique: true, where: "source = 'template'", name: "idx_care_lines_one_adoption"
    add_index :care_lines, :declared_condition, unique: true, where: "active AND declared_condition IS NOT NULL",
                                                 name: "idx_care_lines_one_declared"
    add_check_constraint :care_lines, "source::text = ANY (ARRAY['template'::text, 'custom'::text]) AND " \
                                      "((source::text = 'template') = (template_key IS NOT NULL AND template_version IS NOT NULL AND indicator IS NOT NULL)) AND " \
                                      "(declared_condition IS NULL OR declared_condition::text = ANY (ARRAY['diabetes'::text, 'hypertension'::text, 'pregnancy'::text, 'mental_health'::text])) AND " \
                                      "jsonb_typeof(practices) = 'array'::text AND jsonb_typeof(eligibility) = 'object'::text",
                         name: "ck_care_lines_values"

    create_table :care_line_suggestions, id: :uuid do |t|
      t.references :patient, type: :uuid, foreign_key: true, index: false
      t.references :citizen, type: :uuid, foreign_key: true, index: false
      t.references :care_line, type: :uuid, null: false, foreign_key: true, index: false
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.uuid :enrollment_id
      t.string :reason, null: false
      t.string :evidence_ref, limit: 60
      t.string :status, null: false, default: "pending"
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :decided_at
      t.text :dismiss_reason
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :care_line_suggestions, %i[team_id status created_at], name: "idx_care_line_suggestions_team"
    add_index :care_line_suggestions, %i[care_line_id patient_id], unique: true, where: "status = 'pending' AND patient_id IS NOT NULL",
                                                                   name: "idx_care_line_suggestions_one_patient"
    add_index :care_line_suggestions, %i[care_line_id citizen_id], unique: true, where: "status = 'pending' AND citizen_id IS NOT NULL",
                                                                   name: "idx_care_line_suggestions_one_citizen"
    add_index :care_line_suggestions, :citizen_id, name: "idx_care_line_suggestions_citizen"
    add_index :care_line_suggestions, :patient_id, name: "idx_care_line_suggestions_patient"
    add_check_constraint :care_line_suggestions, "num_nonnulls(patient_id, citizen_id) = 1 AND " \
                                                 "reason::text = ANY (ARRAY['problem'::text, 'age_sex'::text, 'declared'::text, 'resolved_problem'::text]) AND " \
                                                 "((reason::text = 'resolved_problem') = (enrollment_id IS NOT NULL)) AND " \
                                                 "(reason::text <> 'resolved_problem' OR patient_id IS NOT NULL) AND " \
                                                 "status::text = ANY (ARRAY['pending'::text, 'accepted'::text, 'dismissed'::text]) AND " \
                                                 "((status::text = 'pending') = (decided_at IS NULL AND decided_by_user_id IS NULL)) AND " \
                                                 "((status::text = 'dismissed') = (dismiss_reason IS NOT NULL))",
                         name: "ck_care_line_suggestions_values"

    create_table :care_line_enrollments, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :care_line, type: :uuid, null: false, foreign_key: true, index: false
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.references :enrolled_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :suggestion, type: :uuid, foreign_key: { to_table: :care_line_suggestions }, index: { unique: true }
      t.datetime :enrolled_at, null: false
      t.string :source, null: false
      t.text :anchor_date
      t.string :status, null: false, default: "active"
      t.string :ended_reason
      t.text :ended_note
      t.datetime :ended_at
      t.references :ended_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :care_line_enrollments, %i[patient_id care_line_id], unique: true, where: "status = 'active'",
                                                                   name: "idx_care_line_enrollments_one_active"
    add_index :care_line_enrollments, %i[team_id status enrolled_at], name: "idx_care_line_enrollments_team"
    add_index :care_line_enrollments, :patient_id, name: "idx_care_line_enrollments_patient"
    add_check_constraint :care_line_enrollments, "source::text = ANY (ARRAY['suggestion'::text, 'manual'::text]) AND " \
                                                 "((source::text = 'suggestion') = (suggestion_id IS NOT NULL)) AND " \
                                                 "status::text = ANY (ARRAY['active'::text, 'ended'::text]) AND " \
                                                 "((status::text = 'ended') = (ended_reason IS NOT NULL AND ended_at IS NOT NULL AND ended_by_user_id IS NOT NULL)) AND " \
                                                 "(status::text = 'ended' OR ended_note IS NULL) AND " \
                                                 "(ended_reason IS NULL OR ended_reason::text = ANY (ARRAY['discharge'::text, 'death'::text, 'moved'::text, 'pregnancy_ended'::text, 'other'::text]))",
                         name: "ck_care_line_enrollments_values"
    add_foreign_key :care_line_suggestions, :care_line_enrollments, column: :enrollment_id

    create_table :care_outreach_contacts, id: :uuid do |t|
      t.references :enrollment, type: :uuid, null: false, foreign_key: { to_table: :care_line_enrollments }, index: false
      t.string :channel, null: false
      t.string :outcome, null: false
      t.text :note
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :recorded_at, null: false
    end
    add_index :care_outreach_contacts, %i[enrollment_id recorded_at], name: "idx_care_outreach_contacts_enrollment"
    add_check_constraint :care_outreach_contacts, "channel::text = ANY (ARRAY['phone'::text, 'home_visit'::text, 'wpda_message'::text, 'in_person'::text]) AND " \
                                                  "outcome::text = ANY (ARRAY['reached'::text, 'no_answer'::text, 'scheduled'::text, 'refused'::text])",
                         name: "ck_care_outreach_contacts_values"

    create_table :citizen_declared_conditions, id: :uuid do |t|
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.text :condition, null: false
      t.datetime :declared_at, null: false
      t.datetime :withdrawn_at
    end

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
