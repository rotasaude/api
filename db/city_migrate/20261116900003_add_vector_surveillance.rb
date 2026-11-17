# Módulo 35a (ADR 0054; contrato §1, §5–§8; plano, Task 4): a vigilância.
#   - ovitraps: número único entre as ativas, sem caixa; consentimento
#     obrigatório; ativa ⇔ sem data de retirada; do app ⇔ com aparelho;
#     client_uuid único (o item ovitrap_installation do app);
#   - ovitrap_readings: no máximo uma aberta (sem coleta) por ovitrampa; a
#     semana epidemiológica inteira YYYYWW (A-9); coleta com condição; ovos
#     0–9999 só em palheta boa; contagem corrigida só com nota nova (cifrada);
#   - vector_tasks: uma referência só (leitura, notificação ou bloqueio); a
#     ovitrampa copiada da leitura (A-8), com uma intensificação aberta por
#     ovitrampa; fechada ⇔ quem fechou; nota cifrada;
#   - liraa_surveys, liraa_strata, liraa_stratum_blocks, liraa_draw_items: o
#     levantamento draft → drawn → closed; o quarteirão do estrato com o
#     levantamento copiado do estrato (A-7, conferido por trigger) e único
#     por levantamento; início no quarteirão 1–5 só no sorteado (Q16: sempre
#     1); o item do sorteio único por (estrato, domicílio);
#   - transmission_blocks, transmission_block_areas, transmission_block_cases,
#     transmission_block_cycles: o bloqueio confirmado ⇔ active/closed,
#     descartado ⇔ motivo (cifrado); a área única pelo par; o caso único por
#     notificação, com número único e fixo (Q8); o ciclo 1–3 único no bloqueio.
# vector_inspections.liraa_draw_item_id e transmission_block_id ganham a FK
# que a 900002 não pôde dar. field_sync_receipts aceita os itens de ovitrampa
# (W-4). Triggers em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddVectorSurveillance < ActiveRecord::Migration[8.1]
  # Espelhos de VectorControl::Catalog, dos modelos e de FieldSync::Catalog no
  # dia desta migração (a migração não lê código da aplicação: a lista do
  # banco fica fixa no que foi migrado).
  OVITRAP_NUMBER = "^[0-9A-Za-z-]{1,12}$".freeze
  OVITRAP_STATUSES = %w[active removed lost].freeze
  ORIGINS = %w[dashboard field_app].freeze
  CONDITIONS = %w[ok damaged lost dry].freeze
  EGGS = (0..9999)
  TASK_KINDS = %w[ovitrap_intensification case_resident_elsewhere block_case_without_place].freeze
  TASK_STATES = %w[open done dismissed].freeze
  SURVEY_STATUSES = %w[draft drawn closed].freeze
  LIRAA_MODES = %w[standard half census].freeze
  DRAW_ITEM_STATUSES = %w[pending inspected substituted].freeze
  BLOCK_STATUSES = %w[proposed active closed dismissed].freeze
  DISEASE_GROUPS = %w[arbovirus].freeze
  CASE_ADDED_BY = %w[job user].freeze
  UBV_NUMBERS = (1..3)
  ITEM_TYPES = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration family
                  ovitrap_installation ovitrap_collection].freeze
  TABLES = %w[ovitraps ovitrap_readings vector_tasks liraa_surveys liraa_strata liraa_stratum_blocks liraa_draw_items
              transmission_blocks transmission_block_areas transmission_block_cases transmission_block_cycles].freeze

  def up
    create_ovitraps
    create_readings
    create_liraa
    create_transmission_blocks
    create_tasks

    add_foreign_key :vector_inspections, :liraa_draw_items
    add_foreign_key :vector_inspections, :transmission_blocks
    add_index :vector_inspections, :liraa_draw_item_id, where: "liraa_draw_item_id IS NOT NULL", name: "idx_vector_inspections_draw_item"
    add_index :vector_inspections, :transmission_block_id, where: "transmission_block_id IS NOT NULL", name: "idx_vector_inspections_block"

    remove_check_constraint :field_sync_receipts, name: "ck_field_sync_receipts_item_type"
    add_check_constraint :field_sync_receipts, varchar_in("item_type", ITEM_TYPES), name: "ck_field_sync_receipts_item_type"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_ovitraps
    create_table :ovitraps, id: :uuid do |t|
      t.string :number, limit: 12, null: false
      t.references :household, type: :uuid, null: false, foreign_key: true, index: false
      # O quarteirão do imóvel na instalação, congelado (§6: sem quarteirão,
      # household_without_block).
      t.references :city_block, type: :uuid, null: false, foreign_key: true, index: false
      t.timestamptz :consent_at, null: false
      t.date :installed_on, null: false
      t.date :removed_on
      t.string :status, null: false, default: "active"
      t.references :installed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.uuid :client_uuid
      t.references :field_device, type: :uuid, foreign_key: true, index: false
      t.string :origin, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :ovitraps, "lower((number)::text)", unique: true, where: "status::text = 'active'::text", name: "idx_ovitraps_number"
    add_index :ovitraps, :client_uuid, unique: true, where: "client_uuid IS NOT NULL", name: "idx_ovitraps_client_uuid"
    add_index :ovitraps, :household_id, name: "idx_ovitraps_household"
    add_index :ovitraps, :city_block_id, name: "idx_ovitraps_city_block"
    add_check_constraint :ovitraps, "(number)::text ~ '#{OVITRAP_NUMBER}'::text", name: "ck_ovitraps_number"
    add_check_constraint :ovitraps, "status::text = ANY (ARRAY[#{quoted(OVITRAP_STATUSES)}])", name: "ck_ovitraps_status"
    add_check_constraint :ovitraps, "(status::text = 'active'::text) = (removed_on IS NULL) AND (removed_on IS NULL OR removed_on >= installed_on)",
                         name: "ck_ovitraps_removed"
    add_check_constraint :ovitraps,
                         "origin::text = ANY (ARRAY[#{quoted(ORIGINS)}]) AND (origin::text = 'field_app'::text) = (field_device_id IS NOT NULL)",
                         name: "ck_ovitraps_origin"
    add_check_constraint :ovitraps, "version >= 1", name: "ck_ovitraps_version"
  end

  def create_readings
    create_table :ovitrap_readings, id: :uuid do |t|
      t.references :ovitrap, type: :uuid, null: false, foreign_key: true, index: false
      # A palheta: instalada, coletada (com a condição) e contada.
      t.date :installed_on, null: false
      t.date :collected_on
      t.string :condition
      # A-9: a semana epidemiológica de installed_on, YYYYWW (Surveillance::EpiWeek).
      t.integer :epi_week, null: false
      t.integer :egg_count
      t.timestamptz :counted_at
      t.references :counted_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Cifrado com a chave da cidade; só na correção.
      t.text :count_note
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :ovitrap_readings, :ovitrap_id, unique: true, where: "collected_on IS NULL", name: "idx_ovitrap_readings_open"
    # Alvo da FK composta de vector_tasks (A-8: a ovitrampa da tarefa é a da leitura).
    add_index :ovitrap_readings, %i[id ovitrap_id], unique: true, name: "idx_ovitrap_readings_id_ovitrap"
    add_index :ovitrap_readings, %i[ovitrap_id installed_on], name: "idx_ovitrap_readings_ovitrap"
    add_index :ovitrap_readings, :epi_week, name: "idx_ovitrap_readings_epi_week"
    add_index :ovitrap_readings, :collected_on, where: "condition::text = 'ok'::text AND egg_count IS NULL",
                                                name: "idx_ovitrap_readings_pending_count"
    add_check_constraint :ovitrap_readings, "epi_week % 100 BETWEEN 1 AND 53", name: "ck_ovitrap_readings_epi_week"
    add_check_constraint :ovitrap_readings, "(collected_on IS NULL) = (condition IS NULL) AND (collected_on IS NULL OR collected_on >= installed_on)",
                         name: "ck_ovitrap_readings_collection"
    add_check_constraint :ovitrap_readings, "condition IS NULL OR condition::text = ANY (ARRAY[#{quoted(CONDITIONS)}])",
                         name: "ck_ovitrap_readings_condition"
    add_check_constraint :ovitrap_readings, "egg_count BETWEEN #{EGGS.min} AND #{EGGS.max}", name: "ck_ovitrap_readings_eggs"
    # condition IS NOT NULL: sem coleta, `condition = 'ok'` é NULL e o CHECK passaria.
    add_check_constraint :ovitrap_readings, "egg_count IS NULL OR (condition IS NOT NULL AND condition::text = 'ok'::text)",
                         name: "ck_ovitrap_readings_count"
    add_check_constraint :ovitrap_readings,
                         "(egg_count IS NULL) = (counted_at IS NULL) AND (counted_at IS NULL) = (counted_by_user_id IS NULL) AND " \
                         "(count_note IS NULL OR counted_at IS NOT NULL)",
                         name: "ck_ovitrap_readings_counted"
    add_check_constraint :ovitrap_readings, "version >= 1", name: "ck_ovitrap_readings_version"
  end

  def create_liraa
    create_table :liraa_surveys, id: :uuid do |t|
      t.string :name, limit: 80, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.string :status, null: false, default: "draft"
      # A versão dos parâmetros (vector_parameter_versions.version) do sorteio.
      t.integer :parameters_version
      t.timestamptz :drawn_at
      t.timestamptz :closed_at
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :liraa_surveys, %i[status starts_on], name: "idx_liraa_surveys_status"
    add_check_constraint :liraa_surveys, "length(btrim((name)::text)) >= 1", name: "ck_liraa_surveys_name"
    add_check_constraint :liraa_surveys, "ends_on >= starts_on", name: "ck_liraa_surveys_dates"
    add_check_constraint :liraa_surveys, "status::text = ANY (ARRAY[#{quoted(SURVEY_STATUSES)}])", name: "ck_liraa_surveys_status"
    add_check_constraint :liraa_surveys,
                         "(status::text = 'draft'::text) = (drawn_at IS NULL) AND (drawn_at IS NULL) = (parameters_version IS NULL) AND " \
                         "(status::text = 'closed'::text) = (closed_at IS NOT NULL)",
                         name: "ck_liraa_surveys_drawn"
    add_check_constraint :liraa_surveys, "parameters_version IS NULL OR parameters_version >= 1", name: "ck_liraa_surveys_parameters_version"
    add_check_constraint :liraa_surveys, "version >= 1", name: "ck_liraa_surveys_version"

    create_table :liraa_strata, id: :uuid do |t|
      t.references :liraa_survey, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 60, null: false
      t.string :mode, null: false
      # N, n, intervalo e início casual dos quarteirões, na hora do sorteio.
      t.integer :households_count
      t.integer :sample_target
      t.integer :block_interval
      t.integer :random_start
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :liraa_strata, :liraa_survey_id, name: "idx_liraa_strata_survey"
    add_check_constraint :liraa_strata, "length(btrim((name)::text)) >= 1", name: "ck_liraa_strata_name"
    add_check_constraint :liraa_strata, "mode::text = ANY (ARRAY[#{quoted(LIRAA_MODES)}])", name: "ck_liraa_strata_mode"
    add_check_constraint :liraa_strata,
                         "(households_count IS NULL OR households_count >= 0) AND (sample_target IS NULL OR sample_target >= 0) AND " \
                         "(block_interval IS NULL OR block_interval >= 1) AND " \
                         "(random_start IS NULL OR (random_start >= 1 AND (block_interval IS NULL OR random_start <= block_interval)))",
                         name: "ck_liraa_strata_draw"
    add_check_constraint :liraa_strata, "version >= 1", name: "ck_liraa_strata_version"

    create_table :liraa_stratum_blocks, id: :uuid do |t|
      t.references :liraa_stratum, type: :uuid, null: false, foreign_key: { to_table: :liraa_strata }, index: false
      # A-7: cópia do levantamento do estrato (trigger), para o único por levantamento.
      t.references :liraa_survey, type: :uuid, null: false, foreign_key: true, index: false
      t.references :city_block, type: :uuid, null: false, foreign_key: true, index: false
      t.boolean :drawn, null: false, default: false
      t.integer :household_start
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :liraa_stratum_blocks, %i[liraa_survey_id city_block_id], unique: true, name: "idx_liraa_stratum_blocks_block"
    add_index :liraa_stratum_blocks, :liraa_stratum_id, name: "idx_liraa_stratum_blocks_stratum"
    add_check_constraint :liraa_stratum_blocks, "household_start BETWEEN 1 AND 5", name: "ck_liraa_stratum_blocks_household_start"
    add_check_constraint :liraa_stratum_blocks, "drawn = (household_start IS NOT NULL)", name: "ck_liraa_stratum_blocks_drawn"
    add_check_constraint :liraa_stratum_blocks, "version >= 1", name: "ck_liraa_stratum_blocks_version"

    create_table :liraa_draw_items, id: :uuid do |t|
      t.references :liraa_stratum, type: :uuid, null: false, foreign_key: { to_table: :liraa_strata }, index: false
      t.references :city_block, type: :uuid, null: false, foreign_key: true, index: false
      t.references :household, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :status, null: false, default: "pending"
      t.references :substitute_of, type: :uuid, foreign_key: { to_table: :liraa_draw_items }, index: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :liraa_draw_items, %i[liraa_stratum_id household_id], unique: true, name: "idx_liraa_draw_items_household"
    add_index :liraa_draw_items, %i[liraa_stratum_id position], name: "idx_liraa_draw_items_position"
    add_index :liraa_draw_items, :household_id, name: "idx_liraa_draw_items_household_lookup"
    add_check_constraint :liraa_draw_items, "status::text = ANY (ARRAY[#{quoted(DRAW_ITEM_STATUSES)}])", name: "ck_liraa_draw_items_status"
    add_check_constraint :liraa_draw_items, "position >= 1", name: "ck_liraa_draw_items_position"
    add_check_constraint :liraa_draw_items, "substitute_of_id IS NULL OR substitute_of_id <> id", name: "ck_liraa_draw_items_substitute"
    add_check_constraint :liraa_draw_items, "version >= 1", name: "ck_liraa_draw_items_version"
  end

  def create_transmission_blocks
    create_table :transmission_blocks, id: :uuid do |t|
      t.string :status, null: false, default: "proposed"
      t.string :disease_group, null: false
      # Nulo até a coordenação escolher.
      t.references :center_block, type: :uuid, foreign_key: { to_table: :city_blocks }, index: false
      t.timestamptz :confirmed_at
      t.references :confirmed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamptz :closed_at
      # Cifrado com a chave da cidade.
      t.text :dismissed_reason
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :transmission_blocks, %i[status created_at], name: "idx_transmission_blocks_status"
    add_check_constraint :transmission_blocks, "status::text = ANY (ARRAY[#{quoted(BLOCK_STATUSES)}])", name: "ck_transmission_blocks_status"
    add_check_constraint :transmission_blocks, "disease_group::text = ANY (ARRAY[#{quoted(DISEASE_GROUPS)}])",
                         name: "ck_transmission_blocks_disease_group"
    add_check_constraint :transmission_blocks,
                         "(status::text = ANY (ARRAY['active'::text, 'closed'::text])) = (confirmed_at IS NOT NULL) AND " \
                         "(confirmed_at IS NULL) = (confirmed_by_user_id IS NULL)",
                         name: "ck_transmission_blocks_confirmed"
    add_check_constraint :transmission_blocks, "(status::text = 'closed'::text) = (closed_at IS NOT NULL)", name: "ck_transmission_blocks_closed"
    add_check_constraint :transmission_blocks, "(status::text = 'dismissed'::text) = (dismissed_reason IS NOT NULL)",
                         name: "ck_transmission_blocks_dismissed"
    add_check_constraint :transmission_blocks, "version >= 1", name: "ck_transmission_blocks_version"

    create_table :transmission_block_areas, id: :uuid do |t|
      t.references :transmission_block, type: :uuid, null: false, foreign_key: true, index: false
      t.references :city_block, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :transmission_block_areas, %i[transmission_block_id city_block_id], unique: true, name: "idx_transmission_block_areas_pair"
    add_index :transmission_block_areas, :city_block_id, name: "idx_transmission_block_areas_city_block"

    create_table :transmission_block_cases, id: :uuid do |t|
      t.references :transmission_block, type: :uuid, null: false, foreign_key: true, index: false
      t.references :disease_notification, type: :uuid, null: false, foreign_key: true, index: false
      # O suspected_on da notificação.
      t.date :case_on, null: false
      t.string :added_by, null: false
      # "Caso n" (Q8): único na cidade e fixo, mesmo quando o caso muda de bloqueio.
      t.integer :number, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :transmission_block_cases, :disease_notification_id, unique: true, name: "idx_transmission_block_cases_notification"
    add_index :transmission_block_cases, :number, unique: true, name: "idx_transmission_block_cases_number"
    add_index :transmission_block_cases, %i[transmission_block_id case_on], name: "idx_transmission_block_cases_block"
    add_check_constraint :transmission_block_cases, "added_by::text = ANY (ARRAY[#{quoted(CASE_ADDED_BY)}])",
                         name: "ck_transmission_block_cases_added_by"
    add_check_constraint :transmission_block_cases, "number >= 1", name: "ck_transmission_block_cases_number"
    add_check_constraint :transmission_block_cases, "version >= 1", name: "ck_transmission_block_cases_version"

    create_table :transmission_block_cycles, id: :uuid do |t|
      t.references :transmission_block, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :number, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :transmission_block_cycles, %i[transmission_block_id number], unique: true, name: "idx_transmission_block_cycles_number"
    add_check_constraint :transmission_block_cycles, "number BETWEEN #{UBV_NUMBERS.min} AND #{UBV_NUMBERS.max}",
                         name: "ck_transmission_block_cycles_number"
    add_check_constraint :transmission_block_cycles, "ends_on >= starts_on", name: "ck_transmission_block_cycles_dates"
    add_check_constraint :transmission_block_cycles, "version >= 1", name: "ck_transmission_block_cycles_version"
  end

  def create_tasks
    create_table :vector_tasks, id: :uuid do |t|
      t.string :kind, null: false
      t.string :state, null: false, default: "open"
      t.references :ovitrap_reading, type: :uuid, foreign_key: true, index: false
      t.references :disease_notification, type: :uuid, foreign_key: true, index: false
      t.references :transmission_block, type: :uuid, foreign_key: true, index: false
      # A-8: a ovitrampa da leitura, para uma intensificação aberta por ovitrampa.
      t.references :ovitrap, type: :uuid, foreign_key: true, index: false
      t.uuid :suggested_block_ids, array: true, null: false, default: []
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Cifrado com a chave da cidade.
      t.text :closed_note
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :vector_tasks, :ovitrap_id, unique: true, where: "state::text = 'open'::text AND kind::text = 'ovitrap_intensification'::text",
                                          name: "idx_vector_tasks_open_ovitrap"
    add_index :vector_tasks, %i[state created_at], name: "idx_vector_tasks_state"
    add_index :vector_tasks, :ovitrap_reading_id, name: "idx_vector_tasks_reading"
    add_index :vector_tasks, :disease_notification_id, name: "idx_vector_tasks_notification"
    add_index :vector_tasks, :transmission_block_id, name: "idx_vector_tasks_block"
    add_check_constraint :vector_tasks, "kind::text = ANY (ARRAY[#{quoted(TASK_KINDS)}])", name: "ck_vector_tasks_kind"
    add_check_constraint :vector_tasks, "state::text = ANY (ARRAY[#{quoted(TASK_STATES)}])", name: "ck_vector_tasks_state"
    # Uma referência só, a do tipo (§6, §8): intensificação → leitura; caso de
    # fora → notificação; caso sem lugar → a proposta própria do bloqueio.
    add_check_constraint :vector_tasks,
                         "num_nonnulls(ovitrap_reading_id, disease_notification_id, transmission_block_id) = 1 AND " \
                         "(kind::text = 'ovitrap_intensification'::text) = (ovitrap_reading_id IS NOT NULL) AND " \
                         "(kind::text = 'case_resident_elsewhere'::text) = (disease_notification_id IS NOT NULL) AND " \
                         "(kind::text = 'block_case_without_place'::text) = (transmission_block_id IS NOT NULL)",
                         name: "ck_vector_tasks_reference"
    add_check_constraint :vector_tasks, "(ovitrap_reading_id IS NULL) = (ovitrap_id IS NULL)", name: "ck_vector_tasks_ovitrap"
    # A-8: a ovitrampa é a da leitura.
    add_foreign_key :vector_tasks, :ovitrap_readings, column: %i[ovitrap_reading_id ovitrap_id], primary_key: %i[id ovitrap_id],
                                                      name: "fk_vector_tasks_reading_ovitrap"
    add_check_constraint :vector_tasks, "(state::text = 'open'::text) = (closed_by_user_id IS NULL) AND " \
                                        "(closed_note IS NULL OR state::text <> 'open'::text)",
                         name: "ck_vector_tasks_closed"
    add_check_constraint :vector_tasks, "version >= 1", name: "ck_vector_tasks_version"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{list.map { |item| "'#{item}'::character varying::text" }.join(', ')}])"
end
