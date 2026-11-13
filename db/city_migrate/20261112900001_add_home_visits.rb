# Módulo 24b (ADR 0052): visita domiciliar — a atribuição de microárea a outro
# CBO de campo (6A), a folha do dia (`home_visit_days`, a fonte da ficha LEDI
# tipo 8) e a visita. Folha: uma aberta por (profissional, equipe, dia), fecha
# uma vez (pelo dono, pelo job ou cheia) e então congela. Visita: só muda a
# retirada (três campos, uma vez, com a folha aberta). Motivos, medidas,
# observação e motivo da retirada: cifrados com a chave da cidade (colunas
# `text`; lista e objeto vão como JSON serializado ANTES da cifra). A chave do
# aparelho de campo (`field_device_id`) ganha a FK na 900003. Triggers em
# db/city_triggers.sql (o dump não representa trigger). Irreversível.
class AddHomeVisits < ActiveRecord::Migration[8.1]
  # Espelho de HomeVisits::Catalog e do 24a no dia desta migração (a migração não
  # lê código da aplicação: a lista do banco fica fixa no que foi migrado).
  OUTCOMES = [ 1, 2, 3 ].freeze
  SHIFTS = [ 1, 2, 3 ].freeze
  SUBJECTS = %w[resident family_responsible none].freeze
  ORIGINS = %w[dashboard field_app].freeze
  CLOSED_BY = %w[user job full].freeze
  STATES = %w[open closed].freeze
  NON_RESIDENTIAL = %w[2 3 4 5 6 12 13].freeze
  PROPERTY_TYPES = %w[1 2 3 4 5 6 7 8 9 10 11 12 13 99].freeze
  TABLES = %w[micro_area_field_assignments home_visit_days home_visits].freeze

  def up
    create_assignments
    create_days
    create_visits
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_assignments
    create_table :micro_area_field_assignments, id: :uuid do |t|
      t.references :micro_area, type: :uuid, null: false, foreign_key: true, index: false
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.references :assigned_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :ended_at
      t.references :ended_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :micro_area_field_assignments, %i[micro_area_id professional_id], unique: true, where: "ended_at IS NULL",
                                                                                name: "idx_micro_area_field_assignments_active"
    add_index :micro_area_field_assignments, :professional_id, where: "ended_at IS NULL",
                                                               name: "idx_micro_area_field_assignments_professional"
    add_check_constraint :micro_area_field_assignments, "(ended_at IS NULL) = (ended_by_user_id IS NULL)",
                         name: "ck_micro_area_field_assignments_ended"
  end

  def create_days
    create_table :home_visit_days, id: :uuid do |t|
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.string :cbo, limit: 6, null: false
      t.date :day, null: false
      t.integer :sequence, null: false, default: 1
      t.string :state, null: false, default: "open"
      t.datetime :closed_at
      t.string :closed_by
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :home_visit_days, %i[professional_id team_id day sequence], unique: true, name: "idx_home_visit_days_sheet"
    add_index :home_visit_days, %i[professional_id team_id day], unique: true, where: "state = 'open'",
                                                                 name: "idx_home_visit_days_one_open"
    add_index :home_visit_days, %i[state day], where: "state = 'open'", name: "idx_home_visit_days_open_by_day"
    add_check_constraint :home_visit_days,
                         "#{varchar_in('state', STATES)} AND sequence >= 1 AND (closed_by IS NULL OR #{varchar_in('closed_by', CLOSED_BY)})",
                         name: "ck_home_visit_days_values"
    add_check_constraint :home_visit_days,
                         "(state = 'closed') = (closed_at IS NOT NULL) AND (state = 'closed') = (closed_by IS NOT NULL) " \
                         "AND (closed_by_user_id IS NULL OR closed_by = 'user')",
                         name: "ck_home_visit_days_closed"
  end

  def create_visits
    create_table :home_visits, id: :uuid do |t|
      t.references :home_visit_day, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :client_uuid, null: false
      t.datetime :occurred_at, null: false
      t.integer :shift, null: false
      t.references :household, type: :uuid, foreign_key: true, index: false
      t.references :family, type: :uuid, foreign_key: true, index: false
      t.references :patient, type: :uuid, foreign_key: true, index: false
      t.string :subject, null: false
      t.string :property_type, null: false
      t.references :micro_area, type: :uuid, foreign_key: true, index: false
      t.boolean :out_of_area, null: false, default: false
      t.integer :outcome, null: false
      t.boolean :has_reason, null: false, default: false
      t.text :reasons
      t.boolean :shared, null: false, default: false
      t.text :measurements
      t.text :note
      t.datetime :withdrawn_at
      t.references :withdrawn_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :withdrawal_reason
      t.string :origin, null: false
      t.uuid :field_device_id
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :home_visits, :client_uuid, unique: true, name: "idx_home_visits_client_uuid"
    add_index :home_visits, %i[patient_id occurred_at], where: "withdrawn_at IS NULL AND outcome = 1",
                                                        name: "idx_home_visits_patient_done"
    add_index :home_visits, %i[micro_area_id occurred_at], name: "idx_home_visits_micro_area"
    add_index :home_visits, :home_visit_day_id, name: "idx_home_visits_day"
    add_check_constraint :home_visits,
                         "outcome IN (#{OUTCOMES.join(', ')}) AND shift IN (#{SHIFTS.join(', ')}) " \
                         "AND #{varchar_in('property_type', PROPERTY_TYPES)}",
                         name: "ck_home_visits_values"
    add_check_constraint :home_visits, "(micro_area_id IS NULL) = out_of_area", name: "ck_home_visits_area"
    add_check_constraint :home_visits,
                         "#{varchar_in('subject', SUBJECTS)} AND ((subject = 'none') = (patient_id IS NULL))",
                         name: "ck_home_visits_subject"
    add_check_constraint :home_visits, "subject <> 'family_responsible' OR family_id IS NOT NULL", name: "ck_home_visits_family"
    add_check_constraint :home_visits, "outcome = 1 OR NOT has_reason", name: "ck_home_visits_outcome_reason"
    add_check_constraint :home_visits, "(withdrawn_at IS NULL) = (withdrawn_by_user_id IS NULL) AND (withdrawn_at IS NULL) = (withdrawal_reason IS NULL)", name: "ck_home_visits_withdrawn"
    add_check_constraint :home_visits,
                         "#{varchar_not_in('property_type', NON_RESIDENTIAL)} OR (patient_id IS NULL AND family_id IS NULL)",
                         name: "ck_home_visits_non_residential"
    add_check_constraint :home_visits,
                         "#{varchar_in('origin', ORIGINS)} AND (origin = 'field_app') = (field_device_id IS NOT NULL)",
                         name: "ck_home_visits_origin"
  end

  # varchar IN (...) como o PG16 o devolve (e como o dump o grava): migração e
  # carga do esquema acabam com o mesmo texto de CHECK.
  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{varchar_items(list)}])"
  def varchar_not_in(column, list) = "(#{column})::text <> ALL (ARRAY[#{varchar_items(list)}])"
  def varchar_items(list) = list.map { |item| "'#{item}'::character varying::text" }.join(", ")
end
