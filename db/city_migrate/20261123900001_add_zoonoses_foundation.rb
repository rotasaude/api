# Módulo 35b (ADR 0054; contrato §1, Q11–Q13; plano, Task 2): a fundação do
# centro de zoonoses.
#   - memberships: o papel zoonoses_team no CHECK;
#   - animals: o animal com espécie, sexo, porte e situação do contrato; o
#     microchip cifrado determinístico (CityEncryption), único entre os não
#     nulos; o número de registro único sem caixa entre os não nulos; tutor
#     (paciente) só sem community; domicílio, tutor e autor por FK;
#   - zoonoses_parameter_versions: os parâmetros do 35b, só acréscimo (molde
#     do vector_parameter_versions do 35a); a vigente é a maior versão;
#   - ombudsman_subjects.code: marca dos assuntos reservados (§4), único entre
#     os não nulos;
#   - ombudsman_manifestations.place_address: o endereço da ocorrência,
#     cifrado (§4, Q15);
#   - ombudsman_forwardings: o encaminhamento automático grava o ator do
#     sistema (Q13): created_by_user_id passa a aceitar nulo, com
#     created_by_system e o CHECK de exatamente um dos dois;
#   - vector_products: a vacina antirrábica e a coleira entram nas finalidades
#     (Q11), sempre sozinhas, em unidade (un) com carga 1.
# As mutáveis levam version (≥ 1). animals não aceita DELETE nem TRUNCATE;
# situação e castração só andam para a frente (triggers em
# db/city_triggers.sql; o dump não representa trigger). Irreversível.
class AddZoonosesFoundation < ActiveRecord::Migration[8.1]
  # Espelhos de Membership e Zoonoses::Catalog no dia desta migração (a
  # migração não lê código da aplicação: a lista do banco fica fixa no que foi
  # migrado). ROLES = (AddVectorControlTerritory::ROLES + %w[zoonoses_team]).sort,
  # escrita por extenso: no rollout só esta migração é carregada, e a classe da
  # 20261116900001 não existe (membership_roles_spec confere a igualdade).
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier driver endemic_coordinator exam_provider
             exam_regulator health_professional lab_releaser lab_staff municipal_admin ombudsman ombudsman_responder
             ombudsman_staff pharmacist pharmacy_assistant protocol_author protocol_publisher protocol_reviewer
             psychosocial_lead psychosocial_staff stock_keeper surveillance tfd_committee transport_dispatcher
             vector_lab viewer zoonoses_team].freeze
  SPECIES = %w[dog cat other].freeze
  SEXES = %w[male female unknown].freeze
  SIZES = %w[small medium large].freeze
  ANIMAL_STATUSES = %w[active deceased missing transferred].freeze
  PRODUCT_USES = %w[focal perifocal spatial rabies_vaccine collar].freeze
  ZOONOSES_USES = %w[rabies_vaccine collar].freeze

  def up
    remove_check_constraint :memberships, name: "ck_memberships_role"
    add_check_constraint :memberships, "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])", name: "ck_memberships_role"

    create_animals
    create_parameters
    change_ombudsman
    change_vector_products

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_animals
    create_table :animals, id: :uuid do |t|
      t.string :species, null: false
      t.string :name, limit: 60
      t.string :sex, null: false
      t.string :size
      t.string :coat, limit: 40
      t.string :breed, limit: 60
      t.date :birth_estimate_on
      t.text :microchip
      t.string :registry_number, limit: 20
      t.references :household, type: :uuid, foreign_key: true, index: false
      t.references :tutor_patient, type: :uuid, foreign_key: { to_table: :patients }, index: false
      t.boolean :community, null: false, default: false
      t.string :status, null: false, default: "active"
      t.date :status_on
      t.boolean :neutered, null: false, default: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :animals, :microchip, unique: true, where: "microchip IS NOT NULL", name: "idx_animals_microchip"
    add_index :animals, "lower((registry_number)::text)", unique: true, where: "registry_number IS NOT NULL",
                                                          name: "idx_animals_registry_number"
    add_index :animals, :household_id, where: "household_id IS NOT NULL", name: "idx_animals_household"
    add_index :animals, :tutor_patient_id, where: "tutor_patient_id IS NOT NULL", name: "idx_animals_tutor"
    add_check_constraint :animals, "species::text = ANY (ARRAY[#{quoted(SPECIES)}])", name: "ck_animals_species"
    add_check_constraint :animals, "sex::text = ANY (ARRAY[#{quoted(SEXES)}])", name: "ck_animals_sex"
    add_check_constraint :animals, "size IS NULL OR size::text = ANY (ARRAY[#{quoted(SIZES)}])", name: "ck_animals_size"
    add_check_constraint :animals, "status::text = ANY (ARRAY[#{quoted(ANIMAL_STATUSES)}])", name: "ck_animals_status"
    add_check_constraint :animals, "tutor_patient_id IS NULL OR community = false", name: "ck_animals_tutor"
    add_check_constraint :animals, "version >= 1", name: "ck_animals_version"
  end

  def create_parameters
    create_table :zoonoses_parameter_versions, id: :uuid do |t|
      t.integer :version, null: false
      t.jsonb :values, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :zoonoses_parameter_versions, :version, unique: true, name: "idx_zoonoses_parameter_versions_version"
    add_check_constraint :zoonoses_parameter_versions, "version >= 1", name: "ck_zoonoses_parameter_versions_version"
    add_check_constraint :zoonoses_parameter_versions, "jsonb_typeof(\"values\") = 'object'::text",
                         name: "ck_zoonoses_parameter_versions_values"
  end

  def change_ombudsman
    add_column :ombudsman_subjects, :code, :string
    add_index :ombudsman_subjects, :code, unique: true, where: "code IS NOT NULL", name: "idx_ombudsman_subjects_code"

    add_column :ombudsman_manifestations, :place_address, :text

    change_column_null :ombudsman_forwardings, :created_by_user_id, true
    add_column :ombudsman_forwardings, :created_by_system, :boolean, null: false, default: false
    add_check_constraint :ombudsman_forwardings, "(created_by_user_id IS NULL) = created_by_system",
                         name: "ck_ombudsman_forwardings_creator"
  end

  def change_vector_products
    remove_check_constraint :vector_products, name: "ck_vector_products_uses"
    add_check_constraint :vector_products, "cardinality(uses) >= 1 AND uses <@ ARRAY[#{quoted(PRODUCT_USES)}]",
                         name: "ck_vector_products_uses"
    add_check_constraint :vector_products,
                         "NOT (uses && ARRAY[#{quoted(ZOONOSES_USES)}]) OR (cardinality(uses) = 1 AND unit::text = 'un'::text AND charge_size = 1::numeric)",
                         name: "ck_vector_products_zoonoses_uses"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")
end
