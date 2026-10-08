# Módulo 19 (ADR 0031; spec 2026-10-07 §3): nome completo, social e da mãe no
# par (cifrados), o paciente por CPF ligado aos pares validados, divergências
# de perfil entre pares e a lista de problemas como resultado de eventos só de
# acréscimo. As FKs dos eventos para consulta/adendo nascem na 20261007400002.
# Triggers em db/city_triggers.sql.
class AddPatients < ActiveRecord::Migration[8.1]
  def up
    create_table :patients, id: :uuid do |t|
      t.string :cpf, null: false
      t.text :full_name
      t.text :social_name
      t.text :mother_name
      t.text :birth_date
      t.text :sex
      t.timestamps
    end
    add_index :patients, :cpf, unique: true

    add_column :citizens, :full_name, :text
    add_column :citizens, :social_name, :text
    add_column :citizens, :mother_name, :text
    add_column :citizens, :patient_id, :uuid
    add_index :citizens, :patient_id
    add_foreign_key :citizens, :patients

    create_table :patient_profile_divergences, id: :uuid do |t|
      t.uuid :patient_id, null: false
      t.uuid :citizen_id, null: false
      t.text :fields, array: true, null: false
      t.datetime :created_at, null: false
    end
    add_index :patient_profile_divergences, :patient_id
    add_index :patient_profile_divergences, :citizen_id
    add_foreign_key :patient_profile_divergences, :patients
    add_foreign_key :patient_profile_divergences, :citizens
    add_check_constraint :patient_profile_divergences,
                         "cardinality(fields) > 0 AND fields <@ ARRAY['birth_date'::text, 'sex'::text]",
                         name: "ck_patient_profile_divergences_fields"

    create_table :patient_problems, id: :uuid do |t|
      t.uuid :patient_id, null: false
      t.string :terminology, null: false
      t.string :code, limit: 4, null: false
      t.uuid :terminology_release_id, null: false
      t.string :status, null: false
      t.date :onset_on
      t.string :onset_precision
      t.date :resolved_on
      t.timestamps
    end
    add_index :patient_problems, :patient_id
    add_index :patient_problems, %i[patient_id terminology code], unique: true, where: "((status)::text = 'active'::text)",
                                                                   name: "idx_patient_problems_one_active"
    add_foreign_key :patient_problems, :patients
    {
      "ck_patient_problems_terminology" => "terminology::text = ANY (ARRAY['ciap2'::text, 'cid10'::text])",
      "ck_patient_problems_status" => "status::text = ANY (ARRAY['active'::text, 'resolved'::text])",
      "ck_patient_problems_code" => "(terminology::text = 'ciap2'::text AND code::text ~ '^[A-Z][0-9]{2}$'::text) OR " \
                                    "(terminology::text = 'cid10'::text AND code::text ~ '^[A-Z][0-9]{2}[0-9X]?$'::text)",
      "ck_patient_problems_onset" => "(onset_on IS NULL) = (onset_precision IS NULL)",
      "ck_patient_problems_onset_precision" => "onset_precision IS NULL OR onset_precision::text = ANY (ARRAY['day'::text, 'month'::text, 'year'::text])",
      "ck_patient_problems_resolution" => "(status::text = 'resolved'::text) = (resolved_on IS NOT NULL)"
    }.each { |name, expression| add_check_constraint :patient_problems, expression, name: name }

    create_table :patient_problem_events, id: :uuid do |t|
      t.uuid :patient_problem_id, null: false
      t.string :kind, null: false
      t.uuid :consultation_id
      t.uuid :addendum_id
      t.uuid :user_id, null: false
      t.string :status_after, null: false
      t.date :onset_on
      t.string :onset_precision
      t.date :resolved_on
      t.uuid :terminology_release_id
      t.bigint :txid, null: false, default: -> { "txid_current()" }
      t.datetime :created_at, null: false
    end
    add_index :patient_problem_events, :patient_problem_id
    add_index :patient_problem_events, :consultation_id
    add_index :patient_problem_events, :addendum_id
    add_index :patient_problem_events, :user_id
    add_foreign_key :patient_problem_events, :patient_problems, deferrable: :deferred
    add_foreign_key :patient_problem_events, :users
    {
      "ck_patient_problem_events_kind" => "kind::text = ANY (ARRAY['added'::text, 'resolved'::text, 'reactivated'::text, 'onset_corrected'::text])",
      "ck_patient_problem_events_source" => "(consultation_id IS NULL) <> (addendum_id IS NULL)",
      "ck_patient_problem_events_status" => "status_after::text = ANY (ARRAY['active'::text, 'resolved'::text])"
    }.each { |name, expression| add_check_constraint :patient_problem_events, expression, name: name }

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
