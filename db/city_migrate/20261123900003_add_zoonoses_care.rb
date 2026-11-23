# Módulo 35b (ADR 0054; contrato §1, §4–§7, Q16, Q18, Q21; plano, Task 4): a
# demanda, a observação do agressor, a leishmaniose, o canil, a castração e a
# eutanásia, mais as listas do field-sync.
#   - zoonoses_demands: 1:1 com o encaminhamento da ouvidoria (único); o
#     subtipo do §4; o resultado só no `closed`;
#   - bite_observations: 1:1 com a notificação (único); só cão e gato; o fim
#     da observação depois da exposição; estado open | closed (Q16: sem
#     cancelled); closed ⇔ desfecho ⇔ dia do desfecho, e o dia ≥ a exposição;
#   - leish_surveys: população e meta > 0, ao menos um quarteirão,
#     parameters_version ≥ 0; leish_tests: etiqueta única, o ELISA só depois
#     de um DPP reagente, client_uuid único entre os não nulos;
#   - euthanasias: uma por animal, ao menos uma base legal da lista, nota
#     obrigatória (cifrada); leish_dog_outcomes: um por exame, a eutanásia
#     por FK (Q18: decision euthanasia ⇔ euthanasia_id; não há
#     euthanasias.leish_dog_outcome_id);
#   - shelter_stays: uma estada aberta por animal; saída ⇔ dia da saída;
#     adotante só em adopted; observação só na entrada observation;
#     neuterings: uma por animal;
#   - field_sync_receipts aceita os itens animal, rabies_vaccination,
#     leish_collection e collar; field_sync_tombstones aceita as entidades
#     animal e leish_survey e o motivo out_of_scope (Q21).
# Nenhuma das oito some (DELETE e TRUNCATE recusados). Triggers em
# db/city_triggers.sql (o dump não representa trigger). Irreversível.
class AddZoonosesCare < ActiveRecord::Migration[8.1]
  # Espelhos de Zoonoses::Catalog e FieldSync::Catalog no dia desta migração
  # (a migração não lê código da aplicação: a lista do banco fica fixa no que
  # foi migrado).
  SUBTYPES = %w[scorpion bat rodent tick aggressive_animal neurological_animal sporotrichosis other].freeze
  DEMAND_STATES = %w[open scheduled inspected closed].freeze
  DEMAND_OUTCOMES = %w[resolved guidance not_found referred].freeze
  VACCINE_SPECIES = %w[dog cat].freeze
  PLACES = %w[home shelter].freeze
  OBSERVATION_STATES = %w[open closed].freeze
  OBSERVATION_OUTCOMES = %w[healthy died missing rabies_signs sent_to_exam euthanized].freeze
  SURVEY_KINDS = %w[sample census focus].freeze
  SURVEY_STAGES = %w[draft open closed].freeze
  DPP_RESULTS = %w[reactive non_reactive invalid].freeze
  ELISA_RESULTS = %w[reactive non_reactive inconclusive].freeze
  LEISH_DECISIONS = %w[tutor_treatment euthanasia refused].freeze
  ENTRY_KINDS = %w[collection voluntary_surrender observation other].freeze
  EXIT_KINDS = %w[returned adopted death euthanasia transferred].freeze
  EUTHANASIA_REASONS = %w[leishmaniasis rabies_suspect untreatable_suffering public_health_risk other].freeze
  LEGAL_BASES = %w[cfmv_1000_2012 law_14228_2021].freeze
  ITEM_TYPES = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration family
                  ovitrap_installation ovitrap_collection animal rabies_vaccination leish_collection collar].freeze
  TOMBSTONE_ENTITY_TYPES = %w[household registration animal leish_survey].freeze
  TOMBSTONE_REASONS = %w[moved erased out_of_scope].freeze

  def up
    create_demands
    create_observations
    create_surveys
    create_tests
    create_stays
    create_euthanasias
    create_outcomes
    create_neuterings
    change_field_sync

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_demands
    create_table :zoonoses_demands, id: :uuid do |t|
      t.references :ombudsman_forwarding, type: :uuid, null: false, foreign_key: true, index: false
      t.string :subtype, null: false
      t.string :state, null: false, default: "open"
      t.date :scheduled_on
      t.date :inspected_on
      # Cifrado com a chave da cidade.
      t.text :inspection_note
      t.string :outcome
      t.references :assigned_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :zoonoses_demands, :ombudsman_forwarding_id, unique: true, name: "idx_zoonoses_demands_forwarding"
    add_index :zoonoses_demands, %i[state created_at], name: "idx_zoonoses_demands_state"
    add_check_constraint :zoonoses_demands, "subtype::text = ANY (ARRAY[#{quoted(SUBTYPES)}])", name: "ck_zoonoses_demands_subtype"
    add_check_constraint :zoonoses_demands, "state::text = ANY (ARRAY[#{quoted(DEMAND_STATES)}])", name: "ck_zoonoses_demands_state"
    add_check_constraint :zoonoses_demands, "outcome IS NULL OR outcome::text = ANY (ARRAY[#{quoted(DEMAND_OUTCOMES)}])",
                         name: "ck_zoonoses_demands_outcome_list"
    add_check_constraint :zoonoses_demands, "state::text = 'closed'::text OR outcome IS NULL", name: "ck_zoonoses_demands_outcome"
    add_check_constraint :zoonoses_demands, "version >= 1", name: "ck_zoonoses_demands_version"
  end

  def create_observations
    create_table :bite_observations, id: :uuid do |t|
      t.references :disease_notification, type: :uuid, null: false, foreign_key: true, index: false
      t.string :species, null: false
      t.date :exposure_on, null: false
      t.date :ends_on, null: false
      t.string :place, null: false, default: "home"
      t.references :animal, type: :uuid, foreign_key: true, index: false
      t.string :state, null: false, default: "open"
      t.string :outcome
      t.date :outcome_on
      # Cifrado com a chave da cidade.
      t.text :outcome_note
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :bite_observations, :disease_notification_id, unique: true, name: "idx_bite_observations_notification"
    add_index :bite_observations, :animal_id, where: "animal_id IS NOT NULL", name: "idx_bite_observations_animal"
    add_index :bite_observations, :ends_on, where: "state::text = 'open'::text", name: "idx_bite_observations_open"
    add_check_constraint :bite_observations, "species::text = ANY (ARRAY[#{quoted(VACCINE_SPECIES)}])", name: "ck_bite_observations_species"
    add_check_constraint :bite_observations, "ends_on > exposure_on", name: "ck_bite_observations_period"
    add_check_constraint :bite_observations, "place::text = ANY (ARRAY[#{quoted(PLACES)}])", name: "ck_bite_observations_place"
    add_check_constraint :bite_observations, "state::text = ANY (ARRAY[#{quoted(OBSERVATION_STATES)}])", name: "ck_bite_observations_state"
    add_check_constraint :bite_observations, "outcome IS NULL OR outcome::text = ANY (ARRAY[#{quoted(OBSERVATION_OUTCOMES)}])",
                         name: "ck_bite_observations_outcome_list"
    add_check_constraint :bite_observations,
                         "(state::text = 'closed'::text) = (outcome IS NOT NULL) AND (outcome IS NOT NULL) = (outcome_on IS NOT NULL)",
                         name: "ck_bite_observations_outcome"
    add_check_constraint :bite_observations, "outcome_on IS NULL OR outcome_on >= exposure_on", name: "ck_bite_observations_outcome_on"
    add_check_constraint :bite_observations, "version >= 1", name: "ck_bite_observations_version"
  end

  def create_surveys
    create_table :leish_surveys, id: :uuid do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.references :neighborhood, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :city_block_ids, null: false, array: true, default: []
      t.integer :dog_population, null: false
      t.integer :target_dogs, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.string :stage, null: false, default: "draft"
      t.integer :parameters_version, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :leish_surveys, %i[stage starts_on], name: "idx_leish_surveys_stage"
    add_check_constraint :leish_surveys, "char_length(name::text) BETWEEN 1 AND 80", name: "ck_leish_surveys_name"
    add_check_constraint :leish_surveys, "kind::text = ANY (ARRAY[#{quoted(SURVEY_KINDS)}])", name: "ck_leish_surveys_kind"
    add_check_constraint :leish_surveys, "stage::text = ANY (ARRAY[#{quoted(SURVEY_STAGES)}])", name: "ck_leish_surveys_stage"
    add_check_constraint :leish_surveys, "dog_population > 0", name: "ck_leish_surveys_dog_population"
    add_check_constraint :leish_surveys, "target_dogs > 0", name: "ck_leish_surveys_target_dogs"
    add_check_constraint :leish_surveys, "cardinality(city_block_ids) >= 1", name: "ck_leish_surveys_blocks"
    add_check_constraint :leish_surveys, "starts_on <= ends_on", name: "ck_leish_surveys_period"
    add_check_constraint :leish_surveys, "parameters_version >= 0", name: "ck_leish_surveys_parameters_version"
    add_check_constraint :leish_surveys, "version >= 1", name: "ck_leish_surveys_version"
  end

  def create_tests
    create_table :leish_tests, id: :uuid do |t|
      t.references :leish_survey, type: :uuid, foreign_key: true, index: false
      t.references :animal, type: :uuid, null: false, foreign_key: true, index: false
      t.date :collected_on, null: false
      t.string :label, null: false
      t.string :dpp_result
      t.date :dpp_on
      t.string :elisa_result
      t.date :elisa_on
      t.string :elisa_request
      t.references :result_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.uuid :client_uuid
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :leish_tests, :label, unique: true, name: "idx_leish_tests_label"
    add_index :leish_tests, :client_uuid, unique: true, where: "client_uuid IS NOT NULL", name: "idx_leish_tests_client_uuid"
    add_index :leish_tests, %i[leish_survey_id collected_on], where: "leish_survey_id IS NOT NULL", name: "idx_leish_tests_survey"
    add_index :leish_tests, %i[animal_id collected_on], name: "idx_leish_tests_animal"
    add_check_constraint :leish_tests, "dpp_result IS NULL OR dpp_result::text = ANY (ARRAY[#{quoted(DPP_RESULTS)}])",
                         name: "ck_leish_tests_dpp_result"
    add_check_constraint :leish_tests, "elisa_result IS NULL OR elisa_result::text = ANY (ARRAY[#{quoted(ELISA_RESULTS)}])",
                         name: "ck_leish_tests_elisa_result"
    add_check_constraint :leish_tests, "elisa_result IS NULL OR COALESCE(dpp_result::text = 'reactive'::text, false)", name: "ck_leish_tests_elisa_after_dpp"
    add_check_constraint :leish_tests, "elisa_request IS NULL OR char_length(elisa_request::text) BETWEEN 1 AND 30",
                         name: "ck_leish_tests_elisa_request"
    add_check_constraint :leish_tests, "version >= 1", name: "ck_leish_tests_version"
  end

  def create_stays
    create_table :shelter_stays, id: :uuid do |t|
      t.references :animal, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :entry_kind, null: false
      t.date :entered_on, null: false
      t.string :exit_kind
      t.date :exited_on
      t.references :adopter_patient, type: :uuid, foreign_key: { to_table: :patients }, index: false
      t.references :bite_observation, type: :uuid, foreign_key: true, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :shelter_stays, :animal_id, unique: true, where: "exited_on IS NULL", name: "idx_shelter_stays_open"
    add_index :shelter_stays, %i[animal_id entered_on], name: "idx_shelter_stays_animal"
    add_index :shelter_stays, %i[health_unit_id entered_on], name: "idx_shelter_stays_unit"
    add_index :shelter_stays, :bite_observation_id, where: "bite_observation_id IS NOT NULL", name: "idx_shelter_stays_observation"
    add_check_constraint :shelter_stays, "entry_kind::text = ANY (ARRAY[#{quoted(ENTRY_KINDS)}])", name: "ck_shelter_stays_entry_kind"
    add_check_constraint :shelter_stays, "exit_kind IS NULL OR exit_kind::text = ANY (ARRAY[#{quoted(EXIT_KINDS)}])",
                         name: "ck_shelter_stays_exit_kind_list"
    add_check_constraint :shelter_stays, "(exit_kind IS NULL) = (exited_on IS NULL)", name: "ck_shelter_stays_exit"
    add_check_constraint :shelter_stays, "exited_on IS NULL OR exited_on >= entered_on", name: "ck_shelter_stays_period"
    add_check_constraint :shelter_stays, "adopter_patient_id IS NULL OR exit_kind::text = 'adopted'::text", name: "ck_shelter_stays_adopter"
    add_check_constraint :shelter_stays, "bite_observation_id IS NULL OR entry_kind::text = 'observation'::text",
                         name: "ck_shelter_stays_observation"
    add_check_constraint :shelter_stays, "version >= 1", name: "ck_shelter_stays_version"
  end

  def create_euthanasias
    create_table :euthanasias, id: :uuid do |t|
      t.references :animal, type: :uuid, null: false, foreign_key: true, index: false
      t.date :performed_on, null: false
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.string :reason, null: false
      # Cifrado com a chave da cidade.
      t.text :reason_note, null: false
      t.string :legal_basis, null: false, array: true
      t.references :shelter_stay, type: :uuid, foreign_key: true, index: false
      t.references :bite_observation, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :euthanasias, :animal_id, unique: true, name: "idx_euthanasias_animal"
    add_index :euthanasias, :performed_on, name: "idx_euthanasias_day"
    add_index :euthanasias, :shelter_stay_id, where: "shelter_stay_id IS NOT NULL", name: "idx_euthanasias_stay"
    add_index :euthanasias, :bite_observation_id, where: "bite_observation_id IS NOT NULL", name: "idx_euthanasias_observation"
    add_check_constraint :euthanasias, "reason::text = ANY (ARRAY[#{quoted(EUTHANASIA_REASONS)}])", name: "ck_euthanasias_reason"
    add_check_constraint :euthanasias,
                         "cardinality(legal_basis) >= 1 AND legal_basis <@ ARRAY[#{quoted(LEGAL_BASES)}]::character varying[]",
                         name: "ck_euthanasias_legal_basis"
  end

  # Q18: a ligação vai do desfecho à eutanásia.
  def create_outcomes
    create_table :leish_dog_outcomes, id: :uuid do |t|
      t.references :animal, type: :uuid, null: false, foreign_key: true, index: false
      t.references :leish_test, type: :uuid, null: false, foreign_key: true, index: false
      t.string :decision, null: false
      t.date :decided_on, null: false
      # Cifrado com a chave da cidade.
      t.text :note
      t.references :euthanasia, type: :uuid, foreign_key: { to_table: :euthanasias }, index: false
      t.datetime :created_at, null: false
    end
    add_index :leish_dog_outcomes, :leish_test_id, unique: true, name: "idx_leish_dog_outcomes_test"
    add_index :leish_dog_outcomes, :animal_id, name: "idx_leish_dog_outcomes_animal"
    add_index :leish_dog_outcomes, :euthanasia_id, unique: true, where: "euthanasia_id IS NOT NULL", name: "idx_leish_dog_outcomes_euthanasia"
    add_check_constraint :leish_dog_outcomes, "decision::text = ANY (ARRAY[#{quoted(LEISH_DECISIONS)}])", name: "ck_leish_dog_outcomes_decision"
    add_check_constraint :leish_dog_outcomes, "(decision::text = 'euthanasia'::text) = (euthanasia_id IS NOT NULL)",
                         name: "ck_leish_dog_outcomes_euthanasia"
  end

  def create_neuterings
    create_table :neuterings, id: :uuid do |t|
      t.references :animal, type: :uuid, null: false, foreign_key: true, index: false
      t.date :performed_on, null: false
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.references :shelter_stay, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :neuterings, :animal_id, unique: true, name: "idx_neuterings_animal"
    add_index :neuterings, :performed_on, name: "idx_neuterings_day"
  end

  def change_field_sync
    replace_check :field_sync_receipts, "ck_field_sync_receipts_item_type", varchar_in("item_type", ITEM_TYPES)
    replace_check :field_sync_tombstones, "ck_field_sync_tombstones_entity_type", varchar_in("entity_type", TOMBSTONE_ENTITY_TYPES)
    replace_check :field_sync_tombstones, "ck_field_sync_tombstones_reason", varchar_in("reason", TOMBSTONE_REASONS)
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{list.map { |item| "'#{item}'::character varying::text" }.join(', ')}])"

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
