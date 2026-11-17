# Módulo 35a (ADR 0054; contrato §1): vigilância ambiental de endemias — a
# fundação e o território.
#   - memberships: os papéis endemic_coordinator e vector_lab no CHECK;
#   - health_units: o tipo environmental_surveillance (UVZ) no CHECK;
#   - city_blocks: o quarteirão do bairro (número único sem caixa no bairro);
#   - city_block_neighbors: o par de vizinhos guardado uma vez (a < b), único
#     entre os vigentes; nunca apagado: o par desfeito ganha ended_at e pode
#     ser refeito depois (A-6);
#   - household_vector_profiles: o perfil do imóvel (1:1 com o domicílio):
#     quarteirão, risco com a data juntos e o último trabalho, denormalizado;
#   - vector_cadences: a cadência de visita por (bairro, risco, PE), nulo como
#     valor (W-10: o PE não tem risco);
#   - vector_cycles: o ciclo do ano (1–12) sem datas sobrepostas (exclusion
#     GiST, intervalo fechado);
#   - vector_parameter_versions: os parâmetros, só acréscimo; a vigente é a
#     maior versão;
#   - vector_control_settings: uma linha só (id 1), criada sob demanda pelo
#     modelo (sem dado aqui).
# As mutáveis levam version (≥ 1) para o feed do app. Nenhuma das sete aceita
# DELETE nem TRUNCATE (triggers em db/city_triggers.sql; o dump não representa
# trigger). Irreversível.
class AddVectorControlTerritory < ActiveRecord::Migration[8.1]
  # Espelho de Membership, HealthUnit e VectorControl::Catalog no dia desta
  # migração (a migração não lê código da aplicação: a lista do banco fica fixa
  # no que foi migrado).
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier driver endemic_coordinator exam_provider
             exam_regulator health_professional lab_releaser lab_staff municipal_admin ombudsman ombudsman_responder
             ombudsman_staff pharmacist pharmacy_assistant protocol_author protocol_publisher protocol_reviewer
             psychosocial_lead psychosocial_staff stock_keeper surveillance tfd_committee transport_dispatcher
             vector_lab viewer].freeze
  HEALTH_UNIT_KINDS = %w[ubs upa hospital other ceo health_management caps environmental_surveillance].freeze
  RISK_CLASSES = %w[green yellow red gray purple].freeze
  SITUATIONS = %w[worked closed refused vacant].freeze
  BLOCK_NUMBER = "^[0-9A-Za-z-]{1,10}$".freeze
  TABLES = %w[city_blocks city_block_neighbors household_vector_profiles vector_cadences vector_cycles
              vector_parameter_versions vector_control_settings].freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"
    replace_check :health_units, "ck_health_units_kind", "kind::text = ANY (ARRAY[#{quoted(HEALTH_UNIT_KINDS)}]::text[])"

    create_blocks
    create_profiles
    create_cadences_and_cycles
    create_parameters_and_settings

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_blocks
    create_table :city_blocks, id: :uuid do |t|
      t.references :neighborhood, type: :uuid, null: false, foreign_key: true, index: false
      t.string :number, limit: 10, null: false
      t.boolean :active, null: false, default: true
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :city_blocks, "neighborhood_id, lower((number)::text)", unique: true, name: "idx_city_blocks_number"
    add_check_constraint :city_blocks, "(number)::text ~ '#{BLOCK_NUMBER}'::text", name: "ck_city_blocks_number"
    add_check_constraint :city_blocks, "version >= 1", name: "ck_city_blocks_version"

    create_table :city_block_neighbors, id: :uuid do |t|
      t.references :city_block, type: :uuid, null: false, foreign_key: true, index: false
      t.references :neighbor_block, type: :uuid, null: false, foreign_key: { to_table: :city_blocks }, index: false
      t.datetime :ended_at
      t.datetime :created_at, null: false
    end
    add_index :city_block_neighbors, %i[city_block_id neighbor_block_id], unique: true, where: "ended_at IS NULL",
                                                                          name: "idx_city_block_neighbors_pair"
    add_index :city_block_neighbors, :neighbor_block_id, name: "idx_city_block_neighbors_neighbor"
    add_check_constraint :city_block_neighbors, "city_block_id < neighbor_block_id", name: "ck_city_block_neighbors_order"
  end

  def create_profiles
    create_table :household_vector_profiles, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: true, index: false
      t.references :city_block, type: :uuid, foreign_key: true, index: false
      t.string :risk_class
      t.date :risk_assessed_on
      # FK para vector_inspections na 900002 (a tabela nasce lá).
      t.uuid :last_inspection_id
      t.date :last_worked_on
      t.string :last_situation
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :household_vector_profiles, :household_id, unique: true, name: "idx_household_vector_profiles_household"
    add_index :household_vector_profiles, :city_block_id, name: "idx_household_vector_profiles_block"
    add_check_constraint :household_vector_profiles, "risk_class IS NULL OR #{varchar_in('risk_class', RISK_CLASSES)}",
                         name: "ck_household_vector_profiles_risk_class"
    add_check_constraint :household_vector_profiles, "(risk_assessed_on IS NULL) = (risk_class IS NULL)",
                         name: "ck_household_vector_profiles_risk"
    add_check_constraint :household_vector_profiles, "last_situation IS NULL OR #{varchar_in('last_situation', SITUATIONS)}",
                         name: "ck_household_vector_profiles_last_situation"
    add_check_constraint :household_vector_profiles, "version >= 1", name: "ck_household_vector_profiles_version"
  end

  def create_cadences_and_cycles
    create_table :vector_cadences, id: :uuid do |t|
      t.references :neighborhood, type: :uuid, foreign_key: true, index: false
      t.string :risk_class
      t.boolean :strategic_point, null: false, default: false
      t.integer :days, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :vector_cadences, %i[neighborhood_id risk_class strategic_point], unique: true, nulls_not_distinct: true,
                                                                                name: "idx_vector_cadences_key"
    add_check_constraint :vector_cadences, "risk_class IS NULL OR #{varchar_in('risk_class', RISK_CLASSES)}",
                         name: "ck_vector_cadences_risk_class"
    add_check_constraint :vector_cadences, "days >= 7 AND days <= 365", name: "ck_vector_cadences_days"
    add_check_constraint :vector_cadences, "NOT strategic_point OR risk_class IS NULL", name: "ck_vector_cadences_strategic_point"
    add_check_constraint :vector_cadences, "version >= 1", name: "ck_vector_cadences_version"

    create_table :vector_cycles, id: :uuid do |t|
      t.integer :year, null: false
      t.integer :number, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :vector_cycles, %i[year number], unique: true, name: "idx_vector_cycles_number"
    add_check_constraint :vector_cycles, "number >= 1 AND number <= 12", name: "ck_vector_cycles_number"
    add_check_constraint :vector_cycles, "starts_on <= ends_on", name: "ck_vector_cycles_dates"
    add_check_constraint :vector_cycles, "version >= 1", name: "ck_vector_cycles_version"
    add_exclusion_constraint :vector_cycles, "daterange(starts_on, ends_on, '[]'::text) WITH &&", using: :gist,
                                                                                                name: "excl_vector_cycles_overlap"
  end

  def create_parameters_and_settings
    create_table :vector_parameter_versions, id: :uuid do |t|
      t.integer :version, null: false
      t.jsonb :values, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :vector_parameter_versions, :version, unique: true, name: "idx_vector_parameter_versions_version"
    add_check_constraint :vector_parameter_versions, "version >= 1", name: "ck_vector_parameter_versions_version"
    add_check_constraint :vector_parameter_versions, "jsonb_typeof(\"values\") = 'object'::text",
                         name: "ck_vector_parameter_versions_values"

    create_table :vector_control_settings, id: :smallint do |t|
      t.references :stock_location, type: :uuid, foreign_key: true, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_check_constraint :vector_control_settings, "id = 1", name: "ck_vector_control_settings_singleton"
    add_check_constraint :vector_control_settings, "version >= 1", name: "ck_vector_control_settings_version"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  # varchar IN (...) como o PG16 o devolve (e como o dump o grava).
  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{list.map { |item| "'#{item}'::character varying::text" }.join(', ')}])"

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
