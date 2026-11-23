# Módulo 35b (ADR 0054; contrato §1, §3 e Q17; plano, Task 3): a vacinação
# antirrábica animal, a coleira e os documentos do estoque.
#   - rabies_campaigns: nome 1–80, metas ≥ 0, início ≤ fim; uma só `open` por
#     vez (único parcial); a etapa só anda planned → open → closed (trigger);
#   - rabies_vaccinations: a dose, imutável fora da anulação (uma vez, trigger,
#     molde do rota_immunization_guard). Rotina ⇔ sem campanha; casa a casa ⇔
#     com domicílio e sem unidade; sem animal só a dose do posto fixo; uma dose
#     ativa por animal e campanha; a nota adversa e o motivo da anulação são
#     cifrados (CityEncryption);
#   - collars: a coleira, `due_on > placed_on`; uma ativa por animal; só a
#     retirada (removed_on e removal_reason, de NULL a valor, uma vez) muda;
#   - stock_movements: `rabies_vaccination_id` e `collar_id` como documentos;
#     os tipos animal_vaccination (−), animal_vaccination_reversal (+) e
#     collar_placement (−), com kind, sign e document reescritos;
#   - vector_stock_shortfalls (Q17): `source` (inspection | vaccination |
#     collar) e `occurred_on` obrigatórios, com a referência exata por origem;
#     as faltas do 35a migram com `inspection` e o dia da visita.
# As três tabelas nunca somem (DELETE e TRUNCATE recusados). Triggers em
# db/city_triggers.sql (o dump não representa trigger). Irreversível.
class AddRabiesVaccinations < ActiveRecord::Migration[8.1]
  # Espelhos de Zoonoses::Catalog, Pharmacy::Catalog e VectorStockShortfall no
  # dia desta migração (a migração não lê código da aplicação: a lista do
  # banco fica fixa no que foi migrado).
  CAMPAIGN_STAGES = %w[planned open closed].freeze
  MODALITIES = %w[house fixed_post routine].freeze
  VACCINE_SPECIES = %w[dog cat].freeze
  REMOVAL_REASONS = %w[replaced lost death other].freeze
  SHORTFALL_SOURCES = %w[inspection vaccination collar].freeze
  MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return
                      vial_opening immunization immunization_reversal administration
                      vector_application vector_application_reversal
                      animal_vaccination animal_vaccination_reversal collar_placement].freeze
  POSITIVE_KINDS = %w[opening receipt donation transfer_in return immunization_reversal vector_application_reversal
                      animal_vaccination_reversal].freeze
  NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry vial_opening immunization administration vector_application
                      animal_vaccination collar_placement].freeze
  MAX_QUANTITY = "99999.99".freeze
  TIME_ZONE = "America/Sao_Paulo".freeze

  def up
    create_campaigns
    create_vaccinations
    create_collars
    change_stock_movements
    change_shortfalls

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  # As faltas do 35a (todas de inspeção) recebem a origem e o dia da visita.
  # A guarda da falta só deixa a conciliação mudar: fica desligada só aqui
  # (o up termina recriando-a a partir do db/city_triggers.sql). Público para o
  # spec provar o preenchimento.
  def backfill_shortfalls(connection = self.connection)
    connection.execute("ALTER TABLE vector_stock_shortfalls DISABLE TRIGGER vector_stock_shortfalls_guard")
    connection.execute(<<~SQL.squish)
      UPDATE vector_stock_shortfalls AS shortfall
         SET source = 'inspection',
             occurred_on = (visit.occurred_at AT TIME ZONE 'UTC' AT TIME ZONE '#{TIME_ZONE}')::date
        FROM vector_inspection_measures AS measure
        JOIN vector_inspections AS inspection ON inspection.id = measure.vector_inspection_id
        JOIN home_visits AS visit ON visit.id = inspection.home_visit_id
       WHERE measure.id = shortfall.vector_inspection_measure_id
         AND (shortfall.source IS NULL OR shortfall.occurred_on IS NULL)
    SQL
    connection.execute("ALTER TABLE vector_stock_shortfalls ENABLE TRIGGER vector_stock_shortfalls_guard")
  end

  private

  def create_campaigns
    create_table :rabies_campaigns, id: :uuid do |t|
      t.string :name, null: false
      t.integer :year, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.integer :goal_dogs, null: false, default: 0
      t.integer :goal_cats, null: false, default: 0
      t.string :stage, null: false, default: "planned"
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :rabies_campaigns, "((true))", unique: true, where: "stage::text = 'open'::text", name: "idx_rabies_campaigns_open"
    add_check_constraint :rabies_campaigns, "char_length(name::text) BETWEEN 1 AND 80", name: "ck_rabies_campaigns_name"
    add_check_constraint :rabies_campaigns, "goal_dogs >= 0 AND goal_cats >= 0", name: "ck_rabies_campaigns_goals"
    add_check_constraint :rabies_campaigns, "starts_on <= ends_on", name: "ck_rabies_campaigns_period"
    add_check_constraint :rabies_campaigns, "stage::text = ANY (ARRAY[#{quoted(CAMPAIGN_STAGES)}])", name: "ck_rabies_campaigns_stage"
    add_check_constraint :rabies_campaigns, "version >= 1", name: "ck_rabies_campaigns_version"
  end

  def create_vaccinations
    create_table :rabies_vaccinations, id: :uuid do |t|
      t.references :animal, type: :uuid, foreign_key: true, index: false
      t.string :species, null: false
      t.references :campaign, type: :uuid, foreign_key: { to_table: :rabies_campaigns }, index: false
      t.string :modality, null: false
      t.date :vaccinated_on, null: false
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.references :household, type: :uuid, foreign_key: true, index: false
      t.references :vector_product, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, foreign_key: true, index: false
      t.boolean :adverse_event, null: false, default: false
      # Cifrados com a chave da cidade.
      t.text :adverse_note
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.uuid :client_uuid
      t.datetime :cancelled_at
      t.text :cancel_reason
      t.datetime :created_at, null: false
    end
    add_index :rabies_vaccinations, %i[animal_id campaign_id], unique: true,
                                                               where: "cancelled_at IS NULL AND animal_id IS NOT NULL AND campaign_id IS NOT NULL",
                                                               name: "idx_rabies_vaccinations_animal_campaign"
    add_index :rabies_vaccinations, :client_uuid, unique: true, where: "client_uuid IS NOT NULL", name: "idx_rabies_vaccinations_client_uuid"
    add_index :rabies_vaccinations, %i[campaign_id vaccinated_on], where: "campaign_id IS NOT NULL", name: "idx_rabies_vaccinations_campaign"
    add_index :rabies_vaccinations, %i[animal_id vaccinated_on], where: "animal_id IS NOT NULL", name: "idx_rabies_vaccinations_animal"
    add_index :rabies_vaccinations, :vaccinated_on, name: "idx_rabies_vaccinations_day"
    add_check_constraint :rabies_vaccinations, "species::text = ANY (ARRAY[#{quoted(VACCINE_SPECIES)}])", name: "ck_rabies_vaccinations_species"
    add_check_constraint :rabies_vaccinations, "modality::text = ANY (ARRAY[#{quoted(MODALITIES)}])", name: "ck_rabies_vaccinations_modality"
    add_check_constraint :rabies_vaccinations, "(modality::text = 'routine'::text) = (campaign_id IS NULL)", name: "ck_rabies_vaccinations_campaign"
    add_check_constraint :rabies_vaccinations, "(modality::text = 'house'::text) = (household_id IS NOT NULL)",
                         name: "ck_rabies_vaccinations_household"
    add_check_constraint :rabies_vaccinations, "modality::text <> 'house'::text OR health_unit_id IS NULL",
                         name: "ck_rabies_vaccinations_house_unit"
    add_check_constraint :rabies_vaccinations, "animal_id IS NOT NULL OR modality::text = 'fixed_post'::text",
                         name: "ck_rabies_vaccinations_animal"
    add_check_constraint :rabies_vaccinations, "(cancelled_at IS NULL) = (cancel_reason IS NULL)", name: "ck_rabies_vaccinations_cancellation"
  end

  def create_collars
    create_table :collars, id: :uuid do |t|
      t.references :animal, type: :uuid, null: false, foreign_key: true, index: false
      t.references :vector_product, type: :uuid, null: false, foreign_key: true, index: false
      t.date :placed_on, null: false
      t.date :due_on, null: false
      t.date :removed_on
      t.string :removal_reason
      t.uuid :client_uuid
      t.datetime :created_at, null: false
    end
    add_index :collars, :animal_id, unique: true, where: "removed_on IS NULL", name: "idx_collars_active"
    add_index :collars, %i[animal_id placed_on], name: "idx_collars_animal"
    add_index :collars, :due_on, where: "removed_on IS NULL", name: "idx_collars_due"
    add_index :collars, :client_uuid, unique: true, where: "client_uuid IS NOT NULL", name: "idx_collars_client_uuid"
    add_check_constraint :collars, "due_on > placed_on", name: "ck_collars_due"
    add_check_constraint :collars, "(removed_on IS NULL) = (removal_reason IS NULL)", name: "ck_collars_removal"
    add_check_constraint :collars, "removal_reason IS NULL OR removal_reason::text = ANY (ARRAY[#{quoted(REMOVAL_REASONS)}])",
                         name: "ck_collars_removal_reason"
  end

  # A baixa e o estorno da dose; a baixa da coleira.
  def change_stock_movements
    add_reference :stock_movements, :rabies_vaccination, type: :uuid, foreign_key: true, index: false
    add_reference :stock_movements, :collar, type: :uuid, foreign_key: true, index: false
    add_index :stock_movements, :rabies_vaccination_id, where: "rabies_vaccination_id IS NOT NULL",
                                                        name: "idx_stock_movements_rabies_vaccination"
    add_index :stock_movements, :collar_id, where: "collar_id IS NOT NULL", name: "idx_stock_movements_collar"
    replace_check :stock_movements, "ck_stock_movements_kind", "kind::text = ANY (ARRAY[#{quoted(MOVEMENT_KINDS)}])"
    replace_check :stock_movements, "ck_stock_movements_sign",
                  "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY} AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(POSITIVE_KINDS)}]) OR quantity > 0::numeric) AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(NEGATIVE_KINDS)}]) OR quantity < 0::numeric)"
    replace_check :stock_movements, "ck_stock_movements_document",
                  "num_nonnulls(stock_entry_id, stock_transfer_id, dispensation_item_id, stock_adjustment_id, vial_opening_id, immunization_id, " \
                  "urgency_administration_id, vector_inspection_measure_id, rabies_vaccination_id, collar_id) = 1 AND " \
                  "(stock_entry_id IS NOT NULL) = (kind::text = ANY (ARRAY['opening'::text, 'receipt'::text, 'donation'::text])) AND " \
                  "(dispensation_item_id IS NOT NULL) = (kind::text = ANY (ARRAY['dispensing'::text, 'return'::text])) AND " \
                  "(stock_transfer_id IS NULL OR kind::text = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'loss'::text])) AND " \
                  "(stock_adjustment_id IS NULL OR kind::text = ANY (ARRAY['adjustment'::text, 'expiry'::text, 'loss'::text])) AND " \
                  "(kind::text <> ALL (ARRAY['transfer_out'::text, 'transfer_in'::text]) OR stock_transfer_id IS NOT NULL) AND " \
                  "(kind::text <> ALL (ARRAY['adjustment'::text, 'expiry'::text]) OR stock_adjustment_id IS NOT NULL) AND " \
                  "(vial_opening_id IS NOT NULL) = (kind::text = 'vial_opening'::text) AND " \
                  "(immunization_id IS NOT NULL) = (kind::text = ANY (ARRAY['immunization'::text, 'immunization_reversal'::text])) AND " \
                  "(urgency_administration_id IS NOT NULL) = (kind::text = 'administration'::text) AND " \
                  "(vector_inspection_measure_id IS NOT NULL) = " \
                  "(kind::text = ANY (ARRAY['vector_application'::text, 'vector_application_reversal'::text])) AND " \
                  "(rabies_vaccination_id IS NOT NULL) = " \
                  "(kind::text = ANY (ARRAY['animal_vaccination'::text, 'animal_vaccination_reversal'::text])) AND " \
                  "(collar_id IS NOT NULL) = (kind::text = 'collar_placement'::text)"
  end

  # Q17: a falta tem origem e dia; a referência da inspeção passa a anulável.
  def change_shortfalls
    add_column :vector_stock_shortfalls, :source, :string
    add_column :vector_stock_shortfalls, :occurred_on, :date
    add_reference :vector_stock_shortfalls, :rabies_vaccination, type: :uuid, foreign_key: true, index: false
    add_reference :vector_stock_shortfalls, :collar, type: :uuid, foreign_key: true, index: false
    change_column_null :vector_stock_shortfalls, :vector_inspection_measure_id, true

    backfill_shortfalls(connection)

    change_column_null :vector_stock_shortfalls, :source, false
    change_column_null :vector_stock_shortfalls, :occurred_on, false
    add_index :vector_stock_shortfalls, :rabies_vaccination_id, unique: true, where: "rabies_vaccination_id IS NOT NULL",
                                                                name: "idx_vector_stock_shortfalls_rabies_vaccination"
    add_index :vector_stock_shortfalls, :collar_id, unique: true, where: "collar_id IS NOT NULL", name: "idx_vector_stock_shortfalls_collar"
    add_check_constraint :vector_stock_shortfalls, "source::text = ANY (ARRAY[#{quoted(SHORTFALL_SOURCES)}])",
                         name: "ck_vector_stock_shortfalls_source"
    add_check_constraint :vector_stock_shortfalls,
                         "(source::text = 'inspection'::text) = (vector_inspection_measure_id IS NOT NULL) AND " \
                         "(source::text = 'vaccination'::text) = (rabies_vaccination_id IS NOT NULL) AND " \
                         "(source::text = 'collar'::text) = (collar_id IS NOT NULL)",
                         name: "ck_vector_stock_shortfalls_reference"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
