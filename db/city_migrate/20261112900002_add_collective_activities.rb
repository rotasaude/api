# Módulo 24b (ADR 0052): atividade coletiva (ficha LEDI), seus profissionais e
# participantes. A atividade nunca é apagada nem editada: só muda a marca de
# engano (`mistaken_*`, três campos, de NULL a valor, uma vez). Profissionais e
# participantes são só acréscimo. Temas, públicos, práticas, procedimento e motivo
# do engano (atividade) e avaliação, medidas e tabagismo (participante) são
# cifrados com a chave da cidade (colunas `text`; lista, objeto e booleano vão
# como JSON serializado ANTES da cifra). `altered_count` é derivado pelo api (o
# número de participantes com avaliação alterada, Q38): o banco só garante a faixa
# e `<= participants_count`, porque a lista está cifrada. A chave do aparelho de
# campo (`field_device_id`) ganha a FK na 900003. Triggers em db/city_triggers.sql
# (o dump não representa trigger). Irreversível.
class AddCollectiveActivities < ActiveRecord::Migration[8.1]
  # Espelho de CollectiveActivities::Catalog e de HomeVisits::Catalog no dia desta
  # migração (a migração não lê código da aplicação).
  TYPES = (1..7).freeze
  SHIFTS = [ 1, 2, 3 ].freeze
  ORIGINS = %w[dashboard field_app].freeze
  PLACE_TEXT_MAX = 250

  def up
    create_activities
    create_professionals
    create_participants
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_activities
    create_table :collective_activities, id: :uuid do |t|
      t.uuid :client_uuid, null: false
      t.references :team, type: :uuid, null: false, foreign_key: { to_table: :health_teams }, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.string :cbo, limit: 6, null: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.date :held_on, null: false
      t.integer :shift, null: false
      t.integer :activity_type, null: false
      t.references :place_health_unit, type: :uuid, foreign_key: { to_table: :health_units }, index: false
      t.string :place_text, limit: PLACE_TEXT_MAX
      t.integer :participants_count, null: false
      t.integer :altered_count, null: false, default: 0
      t.text :meeting_topics
      t.text :target_audience
      t.text :health_topics
      t.text :health_practices
      t.text :procedure_code
      t.datetime :mistaken_at
      t.references :mistaken_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :mistaken_reason
      t.string :origin, null: false
      t.uuid :field_device_id
      t.datetime :created_at, null: false
    end
    add_index :collective_activities, :client_uuid, unique: true, name: "idx_collective_activities_client_uuid"
    add_index :collective_activities, %i[team_id held_on], name: "idx_collective_activities_team_held_on"
    add_check_constraint :collective_activities,
                         "activity_type BETWEEN #{TYPES.first} AND #{TYPES.last} AND shift IN (#{SHIFTS.join(', ')})",
                         name: "ck_collective_activities_values"
    add_check_constraint :collective_activities, "num_nonnulls(place_health_unit_id, place_text) = 1",
                         name: "ck_collective_activities_place"
    add_check_constraint :collective_activities, "participants_count BETWEEN 1 AND 999",
                         name: "ck_collective_activities_participants_count"
    add_check_constraint :collective_activities, "altered_count BETWEEN 0 AND participants_count",
                         name: "ck_collective_activities_altered_count"
    add_check_constraint :collective_activities,
                         "(mistaken_at IS NULL) = (mistaken_by_user_id IS NULL) AND (mistaken_at IS NULL) = (mistaken_reason IS NULL)",
                         name: "ck_collective_activities_mistaken"
    add_check_constraint :collective_activities,
                         "#{varchar_in('origin', ORIGINS)} AND (origin = 'field_app') = (field_device_id IS NOT NULL)",
                         name: "ck_collective_activities_origin"
  end

  def create_professionals
    create_table :collective_activity_professionals, id: :uuid do |t|
      t.references :collective_activity, type: :uuid, null: false, foreign_key: true, index: false
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.string :cbo, limit: 6, null: false
      t.datetime :created_at, null: false
    end
    add_index :collective_activity_professionals, %i[collective_activity_id professional_id], unique: true,
                                                                                              name: "idx_collective_activity_professionals_unique"
  end

  def create_participants
    create_table :collective_activity_participants, id: :uuid do |t|
      t.references :collective_activity, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.text :altered_evaluation
      t.text :measurements
      t.text :smoking
      t.datetime :created_at, null: false
    end
    add_index :collective_activity_participants, %i[collective_activity_id patient_id], unique: true,
                                                                                        name: "idx_collective_activity_participants_unique"
    add_index :collective_activity_participants, :patient_id, name: "idx_collective_activity_participants_patient"
  end

  # varchar IN (...) como o PG16 o devolve (e como o dump o grava): migração e
  # carga do esquema acabam com o mesmo texto de CHECK.
  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{varchar_items(list)}])"
  def varchar_not_in(column, list) = "(#{column})::text <> ALL (ARRAY[#{varchar_items(list)}])"
  def varchar_items(list) = list.map { |item| "'#{item}'::character varying::text" }.join(", ")
end
