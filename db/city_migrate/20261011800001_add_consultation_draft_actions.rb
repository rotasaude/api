# db/city_migrate/20261011800001_add_consultation_draft_actions.rb
# Rascunho de consulta órfão (card rotasaude/api#51; módulo 19a, ADR 0031): o
# admin municipal descarta o rascunho ou o designa a outro profissional da
# unidade. Descartar marca, não apaga: status `discarded` com discarded_at e
# todo o conteúdo clínico zerado (a linha fica como casca, a consulta "nunca
# some"; documentos clínicos já emitidos seguem apontando para ela). A trilha
# consultation_draft_actions é só acréscimo, com motivo cifrado. O
# `ck_consultations_finalized_care_type` passa a exigir o tipo só da
# finalizada (o rascunho descartado pode não ter tipo). As exceções de trigger
# (marca rota.draft_admin) estão em db/city_triggers.sql. Irreversível.
class AddConsultationDraftActions < ActiveRecord::Migration[8.1]
  STATUSES = %w[draft finalized discarded].freeze
  ACTIONS = %w[discarded reassigned].freeze
  # Conteúdo clínico da consulta (Consultation::CLINICAL_COLUMNS): S, O, A, P e
  # sinais vitais/medições. care_type, ids e datas não são conteúdo clínico.
  CLINICAL_COLUMNS = %w[subjective objective assessment plan systolic diastolic heart_rate respiratory_rate
                        temperature_c spo2 capillary_glucose glucose_moment weight_kg height_cm pain_score].freeze

  def text_in(column, values) = "#{column}::text = ANY (ARRAY[#{values.map { |v| "'#{v}'::text" }.join(', ')}])"

  def up
    add_column :consultations, :discarded_at, :datetime
    remove_check_constraint :consultations, name: "ck_consultations_status"
    add_check_constraint :consultations, text_in("status", STATUSES), name: "ck_consultations_status"
    remove_check_constraint :consultations, name: "ck_consultations_finalized_care_type"
    add_check_constraint :consultations, "status::text <> 'finalized'::text OR care_type IS NOT NULL",
                         name: "ck_consultations_finalized_care_type"
    add_check_constraint :consultations, "(status::text = 'discarded'::text) = (discarded_at IS NOT NULL)",
                         name: "ck_consultations_discard"
    add_check_constraint :consultations,
                         "status::text <> 'discarded'::text OR (#{CLINICAL_COLUMNS.map { |c| "#{c} IS NULL" }.join(' AND ')})",
                         name: "ck_consultations_discarded_empty"

    create_table :consultation_draft_actions, id: :uuid do |t|
      t.uuid :consultation_id, null: false
      t.uuid :attendance_id, null: false
      t.string :action, null: false
      t.uuid :by_user_id, null: false
      t.uuid :previous_author_user_id, null: false
      t.uuid :new_author_user_id
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end
    add_index :consultation_draft_actions, :consultation_id
    add_index :consultation_draft_actions, :created_at
    add_foreign_key :consultation_draft_actions, :consultations
    add_foreign_key :consultation_draft_actions, :attendances
    add_foreign_key :consultation_draft_actions, :users, column: :by_user_id
    add_foreign_key :consultation_draft_actions, :users, column: :previous_author_user_id
    add_foreign_key :consultation_draft_actions, :users, column: :new_author_user_id
    add_check_constraint :consultation_draft_actions, text_in("action", ACTIONS), name: "ck_consultation_draft_actions_action"
    add_check_constraint :consultation_draft_actions, "(action::text = 'reassigned'::text) = (new_author_user_id IS NOT NULL)",
                         name: "ck_consultation_draft_actions_new_author"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
