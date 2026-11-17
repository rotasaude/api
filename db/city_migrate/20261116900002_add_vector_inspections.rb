# Módulo 35a (ADR 0054; contrato §1, §3 e §4; plano, Task 3): o boletim do
# agente na visita e o terceiro domínio do estoque.
#   - vector_products: o produto (código único sem caixa; unidade, carga e
#     usos no domínio); unidade e carga fixas depois do primeiro lote ou
#     medida (trigger, cinto do 409 product_in_use do comando);
#   - vector_inspections: uma por visita do 24b, sempre com domicílio (A-10);
#     o quarteirão congelado; o item do LIRAa e o bloqueio ganham FK na
#     900003 (as tabelas nascem lá);
#   - vector_inspection_deposits: um por grupo, contagens 0–999 e as
#     desigualdades do §3.5;
#   - vector_inspection_measures: única por (inspeção, método, produto), nulo
#     como valor (uma mecânica só); mecânica ⇔ sem produto, cargas e
#     quantidade;
#   - vector_samples: etiqueta única; número 1–99 único na inspeção; larvas
#     1–10; resultado todo ou nada, corrigido só com nota nova (cifrada);
#   - vector_stock_shortfalls: a falta da baixa (uma por medida), conciliada
#     uma vez — pela coordenação (usuário e nota) ou pelo sistema no estorno
#     (sem nenhum dos dois, W-6); a nota é cifrada.
# Estoque (molde do 29, `change_stock_items`/`change_stock_movements`): o local
# vector_control (com unidade); o lote vector_control com `vector_product_id`
# (sem CATMAT, imunobiológico nem fabricante); mínimo, abertura e movimento
# com a terceira chave de item; `vector_application` (−) e o estorno
# `vector_application_reversal` (+, A-1) com a medida por documento.
# household_vector_profiles.last_inspection_id ganha a FK que a 900001 não
# pôde dar. Triggers em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddVectorInspections < ActiveRecord::Migration[8.1]
  # Espelhos de VectorControl::Catalog, Pharmacy::Catalog e
  # VectorStockShortfall no dia desta migração (a migração não lê código da
  # aplicação: a lista do banco fica fixa no que foi migrado).
  ACTIVITIES = %w[li li_t pe ie transmission_block liraa].freeze
  WORK_TYPES = %w[routine pending].freeze
  SITUATIONS = %w[worked closed refused vacant].freeze
  DEPOSIT_GROUPS = %w[A1 A2 B C D1 D2 E].freeze
  DEPOSIT_FIELDS = %w[existing with_water with_larvae eliminated treated].freeze
  DEPOSIT_MAX = 999
  METHODS = %w[mechanical focal perifocal spatial].freeze
  PRODUCT_USES = %w[focal perifocal spatial].freeze
  UNITS = %w[g ml un].freeze
  CHARGES_MAX = 999
  SAMPLE_NUMBERS = (1..99)
  LARVAE = (1..10)
  SHORTFALL_CAUSES = %w[no_location insufficient_balance no_lot].freeze
  LOCATION_KINDS = %w[central unit cold_chain_central vaccine_room vector_control].freeze
  UNIT_LOCATION_KINDS = %w[unit vaccine_room vector_control].freeze
  ITEM_KINDS = %w[medication immunobiological vector_control].freeze
  MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return
                      vial_opening immunization immunization_reversal administration
                      vector_application vector_application_reversal].freeze
  POSITIVE_KINDS = %w[opening receipt donation transfer_in return immunization_reversal vector_application_reversal].freeze
  NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry vial_opening immunization administration vector_application].freeze
  MAX_QUANTITY = "99999.99".freeze
  TABLES = %w[vector_products vector_inspections vector_inspection_deposits vector_inspection_measures vector_samples
              vector_stock_shortfalls].freeze

  def up
    create_products
    create_inspections
    create_samples
    change_stock_locations
    change_stock_items
    change_stock_movements
    create_shortfalls

    add_foreign_key :household_vector_profiles, :vector_inspections, column: :last_inspection_id

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_products
    create_table :vector_products, id: :uuid do |t|
      t.string :code, limit: 10, null: false
      t.string :name, limit: 80, null: false
      t.string :unit, null: false
      t.decimal :charge_size, precision: 10, scale: 2, null: false
      t.text :uses, array: true, null: false
      t.boolean :active, null: false, default: true
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :vector_products, "lower((code)::text)", unique: true, name: "idx_vector_products_code"
    add_check_constraint :vector_products, "unit::text = ANY (ARRAY[#{quoted(UNITS)}])", name: "ck_vector_products_unit"
    add_check_constraint :vector_products, "charge_size > 0::numeric", name: "ck_vector_products_charge_size"
    add_check_constraint :vector_products, "cardinality(uses) >= 1 AND uses <@ ARRAY[#{quoted(PRODUCT_USES)}]",
                         name: "ck_vector_products_uses"
    add_check_constraint :vector_products, "version >= 1", name: "ck_vector_products_version"
  end

  def create_inspections
    create_table :vector_inspections, id: :uuid do |t|
      t.references :home_visit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :household, type: :uuid, null: false, foreign_key: true, index: false
      t.string :activity, null: false
      t.string :work_type, null: false
      t.string :situation, null: false
      t.boolean :recovered, null: false, default: false
      t.boolean :educational_action, null: false
      t.timestamptz :entered_at
      t.timestamptz :left_at
      # FK na 900003 (liraa_draw_items e transmission_blocks nascem lá).
      t.uuid :liraa_draw_item_id
      t.uuid :transmission_block_id
      # O quarteirão do imóvel na hora da visita, congelado.
      t.references :city_block, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :vector_inspections, :home_visit_id, unique: true, name: "idx_vector_inspections_visit"
    add_index :vector_inspections, :household_id, name: "idx_vector_inspections_household"
    add_check_constraint :vector_inspections, "activity::text = ANY (ARRAY[#{quoted(ACTIVITIES)}])", name: "ck_vector_inspections_activity"
    add_check_constraint :vector_inspections, "work_type::text = ANY (ARRAY[#{quoted(WORK_TYPES)}])", name: "ck_vector_inspections_work_type"
    add_check_constraint :vector_inspections, "situation::text = ANY (ARRAY[#{quoted(SITUATIONS)}])", name: "ck_vector_inspections_situation"
    add_check_constraint :vector_inspections, "(entered_at IS NULL) = (left_at IS NULL)", name: "ck_vector_inspections_times"

    create_table :vector_inspection_deposits, id: :uuid do |t|
      t.references :vector_inspection, type: :uuid, null: false, foreign_key: true, index: false
      t.string :group, null: false
      DEPOSIT_FIELDS.each { |field| t.integer field, null: false }
      t.datetime :created_at, null: false
    end
    add_index :vector_inspection_deposits, %i[vector_inspection_id group], unique: true, name: "idx_vector_inspection_deposits_group"
    add_check_constraint :vector_inspection_deposits, "\"group\"::text = ANY (ARRAY[#{quoted(DEPOSIT_GROUPS)}])",
                         name: "ck_vector_inspection_deposits_group"
    add_check_constraint :vector_inspection_deposits,
                         DEPOSIT_FIELDS.map { |field| "#{field} >= 0 AND #{field} <= #{DEPOSIT_MAX}" }.join(" AND "),
                         name: "ck_vector_inspection_deposits_range"
    add_check_constraint :vector_inspection_deposits,
                         "with_water <= existing AND with_larvae <= with_water AND eliminated <= existing AND treated <= with_water",
                         name: "ck_vector_inspection_deposits_counts"

    create_table :vector_inspection_measures, id: :uuid do |t|
      t.references :vector_inspection, type: :uuid, null: false, foreign_key: true, index: false
      t.string :method, null: false
      t.references :vector_product, type: :uuid, foreign_key: true, index: false
      t.decimal :charges, precision: 8, scale: 2
      t.decimal :quantity, precision: 12, scale: 2
      t.datetime :created_at, null: false
    end
    add_index :vector_inspection_measures, %i[vector_inspection_id method vector_product_id], unique: true, nulls_not_distinct: true,
                                                                                             name: "idx_vector_inspection_measures_key"
    add_index :vector_inspection_measures, :vector_product_id, name: "idx_vector_inspection_measures_product"
    add_check_constraint :vector_inspection_measures, "method::text = ANY (ARRAY[#{quoted(METHODS)}])", name: "ck_vector_inspection_measures_method"
    add_check_constraint :vector_inspection_measures,
                         "(method::text = 'mechanical'::text) = (vector_product_id IS NULL) AND " \
                         "(vector_product_id IS NULL) = (charges IS NULL) AND (charges IS NULL) = (quantity IS NULL)",
                         name: "ck_vector_inspection_measures_product"
    add_check_constraint :vector_inspection_measures, "charges IS NULL OR (charges > 0::numeric AND charges <= #{CHARGES_MAX}::numeric)",
                         name: "ck_vector_inspection_measures_charges"
    add_check_constraint :vector_inspection_measures, "quantity IS NULL OR quantity > 0::numeric", name: "ck_vector_inspection_measures_quantity"
  end

  def create_samples
    create_table :vector_samples, id: :uuid do |t|
      t.references :vector_inspection, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :number, null: false
      t.string :deposit_group, null: false
      t.integer :larvae_collected, null: false
      t.string :label, null: false
      t.integer :examined_larvae
      t.integer :aegypti_larvae
      t.integer :albopictus_larvae
      t.timestamptz :result_at
      t.references :result_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Cifrado com a chave da cidade; só na correção.
      t.text :result_note
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :vector_samples, :label, unique: true, name: "idx_vector_samples_label"
    add_index :vector_samples, %i[vector_inspection_id number], unique: true, name: "idx_vector_samples_number"
    add_index :vector_samples, :created_at, where: "result_at IS NULL", name: "idx_vector_samples_pending"
    add_check_constraint :vector_samples, "number >= #{SAMPLE_NUMBERS.min} AND number <= #{SAMPLE_NUMBERS.max}", name: "ck_vector_samples_number"
    add_check_constraint :vector_samples, "deposit_group::text = ANY (ARRAY[#{quoted(DEPOSIT_GROUPS)}])", name: "ck_vector_samples_deposit_group"
    add_check_constraint :vector_samples, "larvae_collected >= #{LARVAE.min} AND larvae_collected <= #{LARVAE.max}", name: "ck_vector_samples_larvae"
    add_check_constraint :vector_samples,
                         "num_nonnulls(examined_larvae, aegypti_larvae, albopictus_larvae, result_at, result_by_user_id) = ANY (ARRAY[0, 5]) AND " \
                         "(result_note IS NULL OR result_at IS NOT NULL)",
                         name: "ck_vector_samples_result"
    add_check_constraint :vector_samples, "examined_larvae IS NULL OR (examined_larvae >= 0 AND examined_larvae <= larvae_collected)",
                         name: "ck_vector_samples_examined"
    add_check_constraint :vector_samples,
                         "aegypti_larvae IS NULL OR (aegypti_larvae >= 0 AND albopictus_larvae >= 0 AND " \
                         "aegypti_larvae + albopictus_larvae <= examined_larvae)",
                         name: "ck_vector_samples_species"
    add_check_constraint :vector_samples, "version >= 1", name: "ck_vector_samples_version"
  end

  # Decisão 29: o local vector_control fica numa unidade (environmental_surveillance, conferido no comando).
  def change_stock_locations
    replace_check :stock_locations, "ck_stock_locations_kind", "kind::text = ANY (ARRAY[#{quoted(LOCATION_KINDS)}])"
    replace_check :stock_locations, "ck_stock_locations_unit",
                  "(kind::text = ANY (ARRAY[#{quoted(UNIT_LOCATION_KINDS)}])) = (health_unit_id IS NOT NULL)"
  end

  # A terceira chave de item (como o 29 fez com o imunobiológico): o lote
  # vector_control só tem o produto; a unidade de dispensação = a do produto
  # é conferida no comando (Task 7), não aqui.
  def change_stock_items
    add_reference :stock_lots, :vector_product, type: :uuid, foreign_key: true, index: false
    replace_check :stock_lots, "ck_stock_lots_item",
                  "item_kind::text = ANY (ARRAY[#{quoted(ITEM_KINDS)}]) AND " \
                  "(item_kind::text = 'immunobiological'::text) = (immunobiological_code IS NOT NULL) AND " \
                  "(item_kind::text = 'vector_control'::text) = (vector_product_id IS NOT NULL) AND " \
                  "(item_kind::text = 'medication'::text) = (catalog_item_id IS NOT NULL) AND " \
                  "(catalog_item_id IS NULL) = (catmat_code IS NULL) AND " \
                  "(item_kind::text = 'immunobiological'::text OR manufacturer_key IS NULL) AND " \
                  "(item_kind::text <> 'immunobiological'::text OR dispensing_unit::text = 'dose'::text)"
    add_index :stock_lots, %i[vector_product_id lot_number], unique: true, where: "vector_product_id IS NOT NULL",
                                                             name: "idx_stock_lots_vector_product_number"

    %i[stock_minimums stock_openings].each do |table|
      add_reference table, :vector_product, type: :uuid, foreign_key: true, index: false
      replace_check table, "ck_#{table}_item", "num_nonnulls(catalog_item_id, immunobiological_code, vector_product_id) = 1"
    end
    add_index :stock_minimums, %i[stock_location_id vector_product_id], unique: true, where: "vector_product_id IS NOT NULL",
                                                                        name: "idx_stock_minimums_vector_product"
    add_index :stock_openings, %i[stock_location_id vector_product_id], unique: true, where: "vector_product_id IS NOT NULL",
                                                                        name: "idx_stock_openings_vector_product_once"
  end

  # A-1: a baixa do boletim (−) e o estorno na retirada da visita (+), com a
  # medida por documento.
  def change_stock_movements
    add_reference :stock_movements, :vector_product, type: :uuid, foreign_key: true, index: false
    add_reference :stock_movements, :vector_inspection_measure, type: :uuid, foreign_key: true, index: false
    add_index :stock_movements, :vector_inspection_measure_id, name: "idx_stock_movements_vector_inspection_measure"
    replace_check :stock_movements, "ck_stock_movements_item", "num_nonnulls(catalog_item_id, immunobiological_code, vector_product_id) = 1"
    replace_check :stock_movements, "ck_stock_movements_kind", "kind::text = ANY (ARRAY[#{quoted(MOVEMENT_KINDS)}])"
    replace_check :stock_movements, "ck_stock_movements_sign",
                  "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY} AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(POSITIVE_KINDS)}]) OR quantity > 0::numeric) AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(NEGATIVE_KINDS)}]) OR quantity < 0::numeric)"
    replace_check :stock_movements, "ck_stock_movements_document",
                  "num_nonnulls(stock_entry_id, stock_transfer_id, dispensation_item_id, stock_adjustment_id, vial_opening_id, immunization_id, " \
                  "urgency_administration_id, vector_inspection_measure_id) = 1 AND " \
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
                  "(kind::text = ANY (ARRAY['vector_application'::text, 'vector_application_reversal'::text]))"
  end

  def create_shortfalls
    create_table :vector_stock_shortfalls, id: :uuid do |t|
      t.references :vector_inspection_measure, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_location, type: :uuid, foreign_key: true, index: false
      t.references :vector_product, type: :uuid, null: false, foreign_key: true, index: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.string :cause, null: false
      t.datetime :reconciled_at
      t.references :reconciled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Cifrado com a chave da cidade.
      t.text :reconciliation_note
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :vector_stock_shortfalls, :vector_inspection_measure_id, unique: true, name: "idx_vector_stock_shortfalls_measure"
    add_index :vector_stock_shortfalls, %i[stock_location_id reconciled_at created_at], name: "idx_vector_stock_shortfalls_location"
    add_check_constraint :vector_stock_shortfalls, "cause::text = ANY (ARRAY[#{quoted(SHORTFALL_CAUSES)}])", name: "ck_vector_stock_shortfalls_cause"
    add_check_constraint :vector_stock_shortfalls, "quantity > 0::numeric", name: "ck_vector_stock_shortfalls_quantity"
    add_check_constraint :vector_stock_shortfalls, "(cause::text = 'no_location'::text) = (stock_location_id IS NULL)",
                         name: "ck_vector_stock_shortfalls_location"
    # W-6: a coordenação concilia com usuário e nota; o sistema (estorno), sem nenhum dos dois.
    add_check_constraint :vector_stock_shortfalls,
                         "(reconciled_by_user_id IS NULL) = (reconciliation_note IS NULL) AND " \
                         "(reconciled_by_user_id IS NULL OR reconciled_at IS NOT NULL)",
                         name: "ck_vector_stock_shortfalls_reconciliation"
    add_check_constraint :vector_stock_shortfalls, "version >= 1", name: "ck_vector_stock_shortfalls_version"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
