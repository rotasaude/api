# Módulo 28 (ADR 0046): saúde bucal. A consulta odontológica é a mesma linha de
# consultations (kind = dental; baseline = exame odontológico inicial), com os
# campos escalares da FAO em colunas (só na dental; zerados pelo descarte do
# api#51). A unidade ganha o tipo `ceo` (perfil do CEO à parte) e a equipe o
# tipo 71 (eSB), associada a uma eSF/eAP. Tabelas novas: lista do TSB/ASB
# (semente inserida aqui), procedimentos, eventos do odontograma (o odontograma
# nunca é coluna: é a dobra dos eventos), plano de tratamento e itens, registro
# periodontal simplificado, periograma, endodontia e sessões, pedidos de
# prótese e etapas. Motivos cifrados com a chave da cidade. Triggers em
# db/city_triggers.sql (o dump não representa trigger nem linha). Irreversível.
class AddOralHealth < ActiveRecord::Migration[8.1]
  # Espelho de DentalCare::Catalog no dia desta migração (a migração não lê
  # código da aplicação: a lista do banco fica fixa no que foi migrado).
  KINDS = %w[general dental].freeze
  GENERAL_CARE_TYPES = [ 1, 2, 5, 6 ].freeze
  DENTAL_CARE_TYPES = [ 2, 4, 5, 6 ].freeze
  CONSULTATION_TYPES = [ 1, 2, 4 ].freeze
  SURVEILLANCE = [ 1, 2, 3, 4, 5, 6, 99 ].freeze
  SUPPLIES = [ 1, 2, 3 ].freeze
  OUTCOMES = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17, 18 ].freeze
  UNIT_KINDS = %w[ubs upa hospital other ceo].freeze
  TEAM_KINDS = %w[70 71 76].freeze
  ORAL_HEALTH_TEAM_KIND = "71".freeze
  CEO_TYPES = %w[I II III].freeze
  CEO_SPECIALTIES = %w[endodontics periodontics oral_surgery stomatology special_needs prosthesis].freeze
  AUXILIARY_DEFAULT_PROCEDURES = %w[0101020058 0101020066 0101020074 0101020082 0101020090 0307030059].freeze
  TEETH = [ 11..18, 21..28, 31..38, 41..48, 51..55, 61..65, 71..75, 81..85 ].flat_map(&:to_a).freeze
  FACES = %w[M D O V L].freeze
  PARTS = %w[crown root].freeze
  SEXTANTS = %w[S1 S2 S3 S4 S5 S6].freeze
  ARCHES = %w[upper lower].freeze
  LOCATION_KINDS = %w[tooth face sextant arch mouth].freeze
  PLAN_STATUSES = %w[open completed cancelled].freeze
  ITEM_STATUSES = %w[planned done cancelled].freeze
  PERIO_SITES = %w[MV V DV ML L DL].freeze
  ENDO_STATUSES = %w[in_progress completed].freeze
  PROSTHESIS_STAGES = %w[impression sent received installed cancelled].freeze
  PROSTHESIS_CODES = %w[0701070099 0701070102 0701070129 0701070137 0701070145].freeze
  QUANTITY = 1..32
  SCREENING_CODES = 0..4
  PROBING_MM = 0..20
  RECESSION_MM = -10..20
  MOBILITY = 0..3
  FURCATION = 0..3
  CANALS = 1..5
  LAB_NAME = 3..120
  PROCEDURE_CODE = "^[0-9]{10}$".freeze
  # O que só a consulta odontológica preenche (e o descarte zera).
  DENTAL_EMPTY = "dental_consultation_type IS NULL AND oral_health_surveillance = '{}'::smallint[] AND supplies = '{}'::smallint[] " \
                 "AND dental_outcomes = '{}'::smallint[] AND pregnant IS NULL AND NOT special_needs".freeze

  def up
    add_consultation_columns
    replace_check :health_units, "ck_health_units_kind", "kind::text = ANY (ARRAY[#{quoted(UNIT_KINDS)}]::text[])"
    replace_check :health_teams, "ck_health_teams_kind", "kind::text = ANY (ARRAY[#{quoted(TEAM_KINDS)}]::text[])"
    add_reference :health_teams, :associated_team, type: :uuid, foreign_key: { to_table: :health_teams }, index: true
    add_check_constraint :health_teams, "associated_team_id IS NULL OR kind::text = '#{ORAL_HEALTH_TEAM_KIND}'::text",
                         name: "ck_health_teams_associated_team"

    create_table :ceo_profiles, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :ceo_type, null: false
      t.string :specialties, array: true, null: false, default: []
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_check_constraint :ceo_profiles, "ceo_type::text = ANY (ARRAY[#{quoted(CEO_TYPES)}]::text[])", name: "ck_ceo_profiles_ceo_type"
    add_check_constraint :ceo_profiles,
                         "cardinality(specialties) >= 1 AND specialties <@ ARRAY[#{quoted(CEO_SPECIALTIES, 'character varying')}]",
                         name: "ck_ceo_profiles_specialties"

    create_table :dental_auxiliary_procedures, id: :uuid do |t|
      t.string :procedure_code, limit: 10, null: false, index: { unique: true }
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    procedure_code_check :dental_auxiliary_procedures
    execute "INSERT INTO dental_auxiliary_procedures (procedure_code, created_at) " \
            "SELECT code, now() FROM unnest(ARRAY[#{quoted(AUXILIARY_DEFAULT_PROCEDURES)}]) AS code " \
            "ON CONFLICT (procedure_code) DO NOTHING"

    create_table :dental_treatment_plans, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :status, null: false
      t.references :opened_in_consultation, type: :uuid, null: false, foreign_key: { to_table: :consultations }, index: false
      t.references :closed_in_consultation, type: :uuid, foreign_key: { to_table: :consultations }, index: false
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :closed_at
      # Cifrado com a chave da cidade.
      t.text :cancel_reason
      t.timestamps
    end
    add_index :dental_treatment_plans, %i[patient_id health_unit_id], unique: true, where: "status::text = 'open'::text",
                                                                      name: "idx_dental_plans_one_open"
    add_index :dental_treatment_plans, :patient_id, name: "idx_dental_plans_patient"
    add_check_constraint :dental_treatment_plans, "status::text = ANY (ARRAY[#{quoted(PLAN_STATUSES)}]::text[])",
                         name: "ck_dental_treatment_plans_status"
    add_check_constraint :dental_treatment_plans, "(status::text = 'open'::text) = (closed_at IS NULL)", name: "ck_dental_treatment_plans_closed"
    add_check_constraint :dental_treatment_plans, "(status::text = 'cancelled'::text) = (cancel_reason IS NOT NULL)",
                         name: "ck_dental_treatment_plans_cancel_reason"

    create_table :dental_treatment_plan_items, id: :uuid do |t|
      t.references :dental_treatment_plan, type: :uuid, null: false, foreign_key: true, index: false
      t.string :procedure_code, limit: 10, null: false
      location_columns(t)
      t.string :status, null: false
      t.references :added_in_consultation, type: :uuid, null: false, foreign_key: { to_table: :consultations }, index: false
      t.references :done_in_consultation, type: :uuid, foreign_key: { to_table: :consultations }, index: false
      t.references :cancelled_in_consultation, type: :uuid, foreign_key: { to_table: :consultations }, index: false
      t.references :cancelled_in_addendum, type: :uuid, foreign_key: { to_table: :consultation_addenda }, index: false
      # Cifrado com a chave da cidade.
      t.text :cancel_reason
      t.timestamps
    end
    add_index :dental_treatment_plan_items, :dental_treatment_plan_id, name: "idx_dental_plan_items_plan"
    procedure_code_check :dental_treatment_plan_items
    location_checks :dental_treatment_plan_items
    add_check_constraint :dental_treatment_plan_items, "status::text = ANY (ARRAY[#{quoted(ITEM_STATUSES)}]::text[])",
                         name: "ck_dental_treatment_plan_items_status"
    add_check_constraint :dental_treatment_plan_items, "(status::text = 'done'::text) = (done_in_consultation_id IS NOT NULL)",
                         name: "ck_dental_treatment_plan_items_done"
    add_check_constraint :dental_treatment_plan_items, "(status::text = 'cancelled'::text) = (cancel_reason IS NOT NULL)",
                         name: "ck_dental_treatment_plan_items_cancel_reason"

    create_table :dental_prosthesis_orders, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      # A consulta da moldagem.
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: false
      t.string :procedure_code, limit: 10, null: false
      t.references :care_provider, type: :uuid, foreign_key: true, index: false
      t.string :laboratory_name, limit: 120
      t.string :stage, null: false
      t.references :installed_in_consultation, type: :uuid, foreign_key: { to_table: :consultations }, index: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :dental_prosthesis_orders, %i[health_unit_id stage created_at], name: "idx_dental_prosthesis_orders_unit_stage"
    add_index :dental_prosthesis_orders, %i[patient_id created_at], name: "idx_dental_prosthesis_orders_patient"
    add_check_constraint :dental_prosthesis_orders, "procedure_code::text = ANY (ARRAY[#{quoted(PROSTHESIS_CODES)}]::text[])",
                         name: "ck_dental_prosthesis_orders_procedure_code"
    add_check_constraint :dental_prosthesis_orders, "num_nonnulls(care_provider_id, laboratory_name) = 1",
                         name: "ck_dental_prosthesis_orders_laboratory"
    add_check_constraint :dental_prosthesis_orders,
                         "laboratory_name IS NULL OR char_length(btrim(laboratory_name::text)) BETWEEN #{LAB_NAME.min} AND #{LAB_NAME.max}",
                         name: "ck_dental_prosthesis_orders_laboratory_name"
    add_check_constraint :dental_prosthesis_orders, "stage::text = ANY (ARRAY[#{quoted(PROSTHESIS_STAGES)}]::text[])",
                         name: "ck_dental_prosthesis_orders_stage"
    add_check_constraint :dental_prosthesis_orders, "(stage::text = 'installed'::text) = (installed_in_consultation_id IS NOT NULL)",
                         name: "ck_dental_prosthesis_orders_installed"

    create_table :dental_prosthesis_stages, id: :uuid do |t|
      t.references :dental_prosthesis_order, type: :uuid, null: false, foreign_key: true, index: false
      t.string :stage, null: false
      t.references :by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      # Cifrado com a chave da cidade.
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_index :dental_prosthesis_stages, %i[dental_prosthesis_order_id created_at], name: "idx_dental_prosthesis_stages_order"
    add_check_constraint :dental_prosthesis_stages, "stage::text = ANY (ARRAY[#{quoted(PROSTHESIS_STAGES)}]::text[])",
                         name: "ck_dental_prosthesis_stages_stage"
    add_check_constraint :dental_prosthesis_stages, "stage::text <> 'cancelled'::text OR reason IS NOT NULL",
                         name: "ck_dental_prosthesis_stages_reason"

    create_table :dental_procedures, id: :uuid do |t|
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.string :procedure_code, limit: 10, null: false
      location_columns(t)
      t.integer :quantity, limit: 2, null: false
      t.references :dental_treatment_plan_item, type: :uuid, foreign_key: true, index: false
      t.references :dental_prosthesis_order, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :dental_procedures, :consultation_id, name: "idx_dental_procedures_consultation"
    add_index :dental_procedures, %i[patient_id created_at], name: "idx_dental_procedures_patient"
    procedure_code_check :dental_procedures
    location_checks :dental_procedures
    add_check_constraint :dental_procedures, "quantity >= #{QUANTITY.min} AND quantity <= #{QUANTITY.max}", name: "ck_dental_procedures_quantity"

    create_table :dental_chart_events, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :addendum, type: :uuid, foreign_key: { to_table: :consultation_addenda }, index: false
      t.integer :tooth, limit: 2, null: false
      t.string :part, limit: 5, null: false, default: "crown"
      t.string :face, limit: 1
      t.string :situation, limit: 40
      t.string :procedure_code, limit: 10
      t.references :dental_procedure, type: :uuid, foreign_key: true, index: false
      t.references :author_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :cbo_code, limit: 6, null: false
      t.datetime :recorded_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :dental_chart_events, %i[patient_id tooth recorded_at id], name: "idx_dental_chart_events_patient_tooth"
    add_index :dental_chart_events, :consultation_id, name: "idx_dental_chart_events_consultation"
    tooth_check :dental_chart_events, nullable: false
    add_check_constraint :dental_chart_events, "part::text = ANY (ARRAY[#{quoted(PARTS)}]::text[])", name: "ck_dental_chart_events_part"
    add_check_constraint :dental_chart_events,
                         "face IS NULL OR (face::text = ANY (ARRAY[#{quoted(FACES)}]::text[]) AND part::text = 'crown'::text)",
                         name: "ck_dental_chart_events_face"
    add_check_constraint :dental_chart_events, "num_nonnulls(situation, procedure_code) >= 1", name: "ck_dental_chart_events_finding"
    add_check_constraint :dental_chart_events, "procedure_code IS NULL OR procedure_code::text ~ '#{PROCEDURE_CODE}'::text",
                         name: "ck_dental_chart_events_procedure_code"
    add_check_constraint :dental_chart_events, "cbo_code::text ~ '^[0-9A-Z]{6}$'::text", name: "ck_dental_chart_events_cbo_code"

    create_table :periodontal_screenings, id: :uuid do |t|
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.string :sextant, limit: 2, null: false
      # Nulo = sextante excluído ("X").
      t.integer :code, limit: 2
      t.boolean :star, null: false, default: false
    end
    add_index :periodontal_screenings, %i[consultation_id sextant], unique: true, name: "idx_periodontal_screenings_sextant"
    add_check_constraint :periodontal_screenings, "sextant::text = ANY (ARRAY[#{quoted(SEXTANTS)}]::text[])",
                         name: "ck_periodontal_screenings_sextant"
    add_check_constraint :periodontal_screenings, "code IS NULL OR (code >= #{SCREENING_CODES.min} AND code <= #{SCREENING_CODES.max})",
                         name: "ck_periodontal_screenings_code"

    create_table :periodontal_charts, id: :uuid do |t|
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :tooth, limit: 2, null: false
      t.integer :mobility, limit: 2
      t.integer :furcation, limit: 2
    end
    add_index :periodontal_charts, %i[consultation_id tooth], unique: true, name: "idx_periodontal_charts_tooth"
    tooth_check :periodontal_charts, nullable: false
    add_check_constraint :periodontal_charts, "mobility IS NULL OR (mobility >= #{MOBILITY.min} AND mobility <= #{MOBILITY.max})",
                         name: "ck_periodontal_charts_mobility"
    add_check_constraint :periodontal_charts, "furcation IS NULL OR (furcation >= #{FURCATION.min} AND furcation <= #{FURCATION.max})",
                         name: "ck_periodontal_charts_furcation"

    create_table :periodontal_sites, id: :uuid do |t|
      t.references :periodontal_chart, type: :uuid, null: false, foreign_key: true, index: false
      t.string :site, limit: 2, null: false
      t.integer :probing_depth_mm, limit: 2, null: false
      t.integer :recession_mm, limit: 2, null: false
      t.boolean :bleeding, null: false, default: false
    end
    add_index :periodontal_sites, %i[periodontal_chart_id site], unique: true, name: "idx_periodontal_sites_site"
    add_check_constraint :periodontal_sites, "site::text = ANY (ARRAY[#{quoted(PERIO_SITES)}]::text[])", name: "ck_periodontal_sites_site"
    add_check_constraint :periodontal_sites, "probing_depth_mm >= #{PROBING_MM.min} AND probing_depth_mm <= #{PROBING_MM.max}",
                         name: "ck_periodontal_sites_probing"
    add_check_constraint :periodontal_sites, "recession_mm >= #{RECESSION_MM.min} AND recession_mm <= #{RECESSION_MM.max}",
                         name: "ck_periodontal_sites_recession"

    create_table :endodontic_treatments, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :tooth, limit: 2, null: false
      t.integer :canals, limit: 2, null: false
      t.string :status, null: false
      t.references :opened_in_consultation, type: :uuid, null: false, foreign_key: { to_table: :consultations }, index: false
      t.references :completed_in_consultation, type: :uuid, foreign_key: { to_table: :consultations }, index: false
      t.timestamps
    end
    add_index :endodontic_treatments, %i[patient_id tooth], unique: true, where: "status::text = 'in_progress'::text",
                                                            name: "idx_endodontic_treatments_one_in_progress"
    add_index :endodontic_treatments, :patient_id, name: "idx_endodontic_treatments_patient"
    tooth_check :endodontic_treatments, nullable: false
    canals_check :endodontic_treatments
    add_check_constraint :endodontic_treatments, "status::text = ANY (ARRAY[#{quoted(ENDO_STATUSES)}]::text[])",
                         name: "ck_endodontic_treatments_status"
    add_check_constraint :endodontic_treatments, "(status::text = 'completed'::text) = (completed_in_consultation_id IS NOT NULL)",
                         name: "ck_endodontic_treatments_completed"

    create_table :endodontic_sessions, id: :uuid do |t|
      t.references :endodontic_treatment, type: :uuid, null: false, foreign_key: true, index: false
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :canals, limit: 2, null: false
      t.datetime :created_at, null: false
    end
    add_index :endodontic_sessions, %i[endodontic_treatment_id created_at], name: "idx_endodontic_sessions_treatment"
    canals_check :endodontic_sessions

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def add_consultation_columns
    add_column :consultations, :kind, :string, null: false, default: "general"
    add_column :consultations, :baseline, :boolean, null: false, default: false
    add_column :consultations, :dental_consultation_type, :integer, limit: 2
    add_column :consultations, :oral_health_surveillance, :integer, limit: 2, array: true, null: false, default: []
    add_column :consultations, :supplies, :integer, limit: 2, array: true, null: false, default: []
    add_column :consultations, :dental_outcomes, :integer, limit: 2, array: true, null: false, default: []
    add_column :consultations, :pregnant, :boolean
    add_column :consultations, :special_needs, :boolean, null: false, default: false
    add_index :consultations, %i[kind status finalized_at], name: "idx_consultations_kind_status_finalized"

    add_check_constraint :consultations, "kind::text = ANY (ARRAY[#{quoted(KINDS)}]::text[])", name: "ck_consultations_kind"
    add_check_constraint :consultations, "NOT baseline OR kind::text = 'dental'::text", name: "ck_consultations_baseline"
    add_check_constraint :consultations, "dental_consultation_type IS NULL OR dental_consultation_type = ANY (ARRAY[#{CONSULTATION_TYPES.join(', ')}])",
                         name: "ck_consultations_dental_consultation_type"
    add_check_constraint :consultations,
                         "oral_health_surveillance <@ ARRAY[#{SURVEILLANCE.join(', ')}]::smallint[] AND cardinality(oral_health_surveillance) <= 7",
                         name: "ck_consultations_oral_health_surveillance"
    add_check_constraint :consultations, "supplies <@ ARRAY[#{SUPPLIES.join(', ')}]::smallint[]", name: "ck_consultations_supplies"
    add_check_constraint :consultations, "dental_outcomes <@ ARRAY[#{OUTCOMES.join(', ')}]::smallint[]", name: "ck_consultations_dental_outcomes"
    add_check_constraint :consultations, "kind::text = 'dental'::text OR (#{DENTAL_EMPTY})", name: "ck_consultations_dental_fields"
    replace_check :consultations, "ck_consultations_care_type",
                  "care_type IS NULL OR (kind::text = 'general'::text AND care_type = ANY (ARRAY[#{GENERAL_CARE_TYPES.join(', ')}])) " \
                  "OR (kind::text = 'dental'::text AND care_type = ANY (ARRAY[#{DENTAL_CARE_TYPES.join(', ')}]))"
    replace_check :consultations, "ck_consultations_finalized_care_type",
                  "status::text <> 'finalized'::text OR care_type IS NOT NULL OR baseline"
    replace_check :consultations, "ck_consultations_discarded_empty",
                  "status::text <> 'discarded'::text OR (subjective IS NULL AND objective IS NULL AND assessment IS NULL AND plan IS NULL " \
                  "AND systolic IS NULL AND diastolic IS NULL AND heart_rate IS NULL AND respiratory_rate IS NULL AND temperature_c IS NULL " \
                  "AND spo2 IS NULL AND capillary_glucose IS NULL AND glucose_moment IS NULL AND weight_kg IS NULL AND height_cm IS NULL " \
                  "AND pain_score IS NULL AND #{DENTAL_EMPTY})"
  end

  def location_columns(t)
    t.string :location_kind, null: false
    t.integer :tooth, limit: 2
    t.string :face, limit: 1
    t.string :sextant, limit: 2
    t.string :arch, limit: 5
  end

  # Desvio 6: tooth exige o dente; face, dente e face; sextant, o sextante;
  # arch, a arcada; mouth, nada.
  def location_checks(table)
    add_check_constraint table, "location_kind::text = ANY (ARRAY[#{quoted(LOCATION_KINDS)}]::text[])", name: "ck_#{table}_location_kind"
    tooth_check table, nullable: true
    add_check_constraint table,
                         "(face IS NULL OR face::text = ANY (ARRAY[#{quoted(FACES)}]::text[])) AND " \
                         "(sextant IS NULL OR sextant::text = ANY (ARRAY[#{quoted(SEXTANTS)}]::text[])) AND " \
                         "(arch IS NULL OR arch::text = ANY (ARRAY[#{quoted(ARCHES)}]::text[])) AND (" \
                         "(location_kind::text = 'tooth'::text AND tooth IS NOT NULL AND face IS NULL AND sextant IS NULL AND arch IS NULL) OR " \
                         "(location_kind::text = 'face'::text AND tooth IS NOT NULL AND face IS NOT NULL AND sextant IS NULL AND arch IS NULL) OR " \
                         "(location_kind::text = 'sextant'::text AND tooth IS NULL AND face IS NULL AND sextant IS NOT NULL AND arch IS NULL) OR " \
                         "(location_kind::text = 'arch'::text AND tooth IS NULL AND face IS NULL AND sextant IS NULL AND arch IS NOT NULL) OR " \
                         "(location_kind::text = 'mouth'::text AND tooth IS NULL AND face IS NULL AND sextant IS NULL AND arch IS NULL))",
                         name: "ck_#{table}_location"
  end

  def tooth_check(table, nullable:)
    list = "tooth = ANY (ARRAY[#{TEETH.join(', ')}])"
    add_check_constraint table, nullable ? "tooth IS NULL OR #{list}" : list, name: "ck_#{table}_tooth"
  end

  def canals_check(table)
    add_check_constraint table, "canals >= #{CANALS.min} AND canals <= #{CANALS.max}", name: "ck_#{table}_canals"
  end

  def procedure_code_check(table)
    add_check_constraint table, "procedure_code::text ~ '#{PROCEDURE_CODE}'::text", name: "ck_#{table}_procedure_code"
  end

  def quoted(list, type = "text") = list.map { |value| "'#{value}'::#{type}" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
