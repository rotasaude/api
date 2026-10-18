# Módulo 21c (ADR 0038): qualidade e insumos do laboratório municipal.
# Aparelhos e vínculo exame × aparelho; CIQ (materiais, lotes com códigos
# por nível, referências versionadas, corridas, valores, regras, bloqueios,
# exceções, revisões); CEQ; estoque com lotes, movimentos e lote em uso; o
# lote de reagente em cada resultado. Triggers em db/city_triggers.sql. Irreversível.
class AddLabQualitySupplies < ActiveRecord::Migration[8.1]
  SECTORS = %w[biochemistry hematology immunology urinalysis parasitology microbiology].freeze

  def up
    create_table :lab_instruments, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 80, null: false
      t.string :manufacturer, limit: 80
      t.string :model, limit: 80
      t.string :serial_number, limit: 60
      t.string :sector, null: false
      t.string :hl7_equipment_id, limit: 50
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :lab_instruments, "exam_provider_id, lower((name)::text)", unique: true, name: "idx_lab_instruments_name"
    add_index :lab_instruments, "exam_provider_id, upper((hl7_equipment_id)::text)", unique: true,
              where: "hl7_equipment_id IS NOT NULL", name: "idx_lab_instruments_hl7"
    add_check_constraint :lab_instruments, "sector::text = ANY (ARRAY[#{quoted(SECTORS)}]::text[])", name: "ck_lab_instruments_sector"
    add_check_constraint :lab_instruments, "hl7_equipment_id IS NULL OR hl7_equipment_id::text ~ '^[A-Za-z0-9._-]{1,50}$'::text",
                         name: "ck_lab_instruments_hl7"

    add_reference :lab_exam_versions, :lab_instrument, type: :uuid, foreign_key: true, index: true

    create_table :lab_qc_materials, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: true
      t.string :name, limit: 80, null: false
      t.string :manufacturer, limit: 80
      t.jsonb :levels, null: false
      t.jsonb :analytes, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :lab_qc_materials, "jsonb_typeof(levels) = 'array' AND jsonb_array_length(levels) BETWEEN 1 AND 6", name: "ck_lab_qc_materials_levels"
    add_check_constraint :lab_qc_materials, "jsonb_typeof(analytes) = 'array' AND jsonb_array_length(analytes) BETWEEN 1 AND 60", name: "ck_lab_qc_materials_analytes"

    create_table :lab_qc_lots, id: :uuid do |t|
      t.references :lab_qc_material, type: :uuid, null: false, foreign_key: true, index: false
      t.string :lot_number, limit: 40, null: false
      t.date :expires_on, null: false
      t.string :status, null: false, default: "in_use"
      t.date :opened_on, null: false
      t.date :closed_on
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :lab_qc_lots, %i[lab_qc_material_id lot_number], unique: true, name: "idx_lab_qc_lots_number"
    add_check_constraint :lab_qc_lots, "status::text = ANY (ARRAY['in_use'::text, 'closed'::text])", name: "ck_lab_qc_lots_status"
    add_check_constraint :lab_qc_lots, "(status::text = 'closed'::text) = (closed_on IS NOT NULL)", name: "ck_lab_qc_lots_closed"

    create_table :lab_qc_lot_barcodes, id: :uuid do |t|
      t.references :lab_qc_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.string :level, limit: 40, null: false
      t.string :barcode, limit: 30, null: false
      t.datetime :created_at, null: false
    end
    # C-E13: o código de barras do controle é único sem diferenciar caixa.
    add_index :lab_qc_lot_barcodes, "lower(barcode::text)", unique: true, name: "idx_lab_qc_lot_barcodes_barcode_ci"
    add_index :lab_qc_lot_barcodes, %i[lab_qc_lot_id level], unique: true, name: "idx_lab_qc_lot_barcodes_level"
    add_check_constraint :lab_qc_lot_barcodes, "barcode::text ~ '^[A-Za-z0-9._-]{3,30}$'::text AND barcode::text !~ '^[0-9]{10}$'::text",
                         name: "ck_lab_qc_lot_barcodes_barcode"

    create_table :lab_qc_targets, id: :uuid do |t|
      t.references :lab_qc_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.string :level, limit: 40, null: false
      t.string :analyte_key, limit: 40, null: false
      t.references :lab_instrument, type: :uuid, null: false, foreign_key: true, index: true
      t.integer :version, null: false
      t.string :source, null: false
      t.decimal :mean, precision: 14, scale: 4, null: false
      t.decimal :sd, precision: 14, scale: 4, null: false
      t.integer :based_on_runs
      t.text :reason
      t.references :accepted_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :accepted_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :lab_qc_targets, %i[lab_qc_lot_id level analyte_key lab_instrument_id version], unique: true, name: "idx_lab_qc_targets_version"
    add_check_constraint :lab_qc_targets, "source::text = ANY (ARRAY['package_insert'::text, 'laboratory'::text])", name: "ck_lab_qc_targets_source"
    add_check_constraint :lab_qc_targets, "(source::text = 'laboratory'::text) = (based_on_runs IS NOT NULL)", name: "ck_lab_qc_targets_runs"
    add_check_constraint :lab_qc_targets, "sd > 0 AND version >= 1", name: "ck_lab_qc_targets_numbers"

    create_table :lab_qc_runs, id: :uuid do |t|
      t.references :lab_instrument, type: :uuid, null: false, foreign_key: true, index: false
      t.string :sector, null: false
      t.string :status, null: false, default: "open"
      t.datetime :started_at, null: false
      t.datetime :evaluated_at
      t.references :opened_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :lab_qc_runs, %i[lab_instrument_id started_at], name: "idx_lab_qc_runs_instrument"
    add_check_constraint :lab_qc_runs, "status::text = ANY (ARRAY['open'::text, 'approved'::text, 'warning'::text, 'rejected'::text])", name: "ck_lab_qc_runs_status"
    add_check_constraint :lab_qc_runs, "status::text = 'open'::text OR evaluated_at IS NOT NULL", name: "ck_lab_qc_runs_evaluated"

    create_table :lab_supplies, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 120, null: false
      t.string :kind, null: false
      t.string :unit, limit: 20, null: false
      t.integer :tests_per_package
      t.integer :minimum_stock, null: false, default: 0
      t.integer :expiry_alert_days, null: false, default: 30
      t.jsonb :lab_exam_ids, null: false, default: []
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :lab_supplies, "exam_provider_id, lower((name)::text)", unique: true, name: "idx_lab_supplies_name"
    add_check_constraint :lab_supplies, "kind::text = ANY (ARRAY['reagent'::text, 'calibrator'::text, 'control'::text, 'consumable'::text])", name: "ck_lab_supplies_kind"
    add_check_constraint :lab_supplies, "(kind::text = 'reagent'::text) = (tests_per_package IS NOT NULL) AND (tests_per_package IS NULL OR tests_per_package BETWEEN 1 AND 100000)",
                         name: "ck_lab_supplies_tests"
    add_check_constraint :lab_supplies, "minimum_stock BETWEEN 0 AND 100000 AND expiry_alert_days BETWEEN 1 AND 365 AND jsonb_typeof(lab_exam_ids) = 'array'",
                         name: "ck_lab_supplies_numbers"

    create_table :lab_supply_lots, id: :uuid do |t|
      t.references :lab_supply, type: :uuid, null: false, foreign_key: true, index: false
      t.string :lot_number, limit: 40, null: false
      t.date :expires_on, null: false
      t.string :supplier, limit: 120, null: false
      t.string :origin, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :lab_supply_lots, %i[lab_supply_id lot_number], unique: true, name: "idx_lab_supply_lots_number"
    add_check_constraint :lab_supply_lots, "origin::text = ANY (ARRAY['purchase'::text, 'donation'::text, 'loan'::text])", name: "ck_lab_supply_lots_origin"

    create_table :lab_supply_movements, id: :uuid do |t|
      t.references :lab_supply_lot, type: :uuid, null: false, foreign_key: true, index: true
      t.string :kind, null: false
      t.integer :quantity, null: false
      t.text :reason
      t.string :document, limit: 60
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :recorded_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :lab_supply_movements, %i[kind recorded_at], name: "idx_lab_supply_movements_kind"
    add_check_constraint :lab_supply_movements,
                         "kind::text = ANY (ARRAY['receipt'::text, 'opening'::text, 'loss'::text, 'expiry'::text, 'adjustment'::text])",
                         name: "ck_lab_supply_movements_kind"
    add_check_constraint :lab_supply_movements,
                         "quantity <> 0 AND abs(quantity) <= 100000 AND (kind::text <> 'receipt'::text OR quantity > 0) " \
                         "AND (kind::text NOT IN ('opening', 'loss', 'expiry') OR quantity < 0)",
                         name: "ck_lab_supply_movements_sign"
    add_check_constraint :lab_supply_movements, "kind::text IN ('receipt', 'opening') OR reason IS NOT NULL", name: "ck_lab_supply_movements_reason"

    create_table :lab_supply_in_use, id: :uuid do |t|
      t.references :lab_supply_lot, type: :uuid, null: false, foreign_key: true, index: true
      t.references :lab_instrument, type: :uuid, null: false, foreign_key: true, index: false
      t.references :lab_exam, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.references :started_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :ended_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :lab_supply_in_use, %i[lab_instrument_id lab_exam_id], unique: true, where: "ended_at IS NULL", name: "idx_lab_supply_in_use_current"
    add_index :lab_supply_in_use, %i[lab_instrument_id started_at], name: "idx_lab_supply_in_use_instrument"

    add_reference :lab_results, :reagent_lot, type: :uuid, foreign_key: { to_table: :lab_supply_lots }, index: true

    create_table :lab_qc_values, id: :uuid do |t|
      t.references :lab_qc_run, type: :uuid, null: false, foreign_key: true, index: true
      t.references :lab_qc_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.string :level, limit: 40, null: false
      t.string :analyte_key, limit: 40, null: false
      t.decimal :value, precision: 14, scale: 4, null: false
      t.string :source, null: false
      t.references :lab_hl7_receipt, type: :uuid, foreign_key: true, index: true
      t.decimal :z_score, precision: 8, scale: 3, null: false
      t.references :lab_qc_target, type: :uuid, null: false, foreign_key: true, index: false
      t.jsonb :rules_fired, null: false, default: []
      t.string :outcome, null: false
      t.references :reagent_lot, type: :uuid, foreign_key: { to_table: :lab_supply_lots }, index: true
      t.references :entered_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :entered_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :lab_qc_values, %i[lab_qc_lot_id level analyte_key entered_at], name: "idx_lab_qc_values_series"
    add_check_constraint :lab_qc_values, "source::text = ANY (ARRAY['typed'::text, 'hl7'::text])", name: "ck_lab_qc_values_source"
    add_check_constraint :lab_qc_values, "outcome::text = ANY (ARRAY['ok'::text, 'warning'::text, 'reject'::text])", name: "ck_lab_qc_values_outcome"
    add_check_constraint :lab_qc_values, "entered_by_user_id IS NOT NULL OR lab_hl7_receipt_id IS NOT NULL", name: "ck_lab_qc_values_actor"
    add_check_constraint :lab_qc_values, "source::text = 'typed'::text OR lab_hl7_receipt_id IS NOT NULL", name: "ck_lab_qc_values_hl7"
    add_check_constraint :lab_qc_values, "jsonb_typeof(rules_fired) = 'array'", name: "ck_lab_qc_values_rules"

    create_table :lab_qc_rules, id: :uuid do |t|
      t.references :lab_instrument, type: :uuid, null: false, foreign_key: true, index: false
      t.string :analyte_key, limit: 40, null: false
      t.jsonb :rules, null: false
      t.text :justification
      t.references :changed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :lab_qc_rules, %i[lab_instrument_id analyte_key created_at], name: "idx_lab_qc_rules_pair"
    add_check_constraint :lab_qc_rules, "jsonb_typeof(rules) = 'object'", name: "ck_lab_qc_rules_rules"

    create_table :lab_qc_blocks, id: :uuid do |t|
      t.references :lab_instrument, type: :uuid, null: false, foreign_key: true, index: false
      t.string :analyte_key, limit: 40, null: false
      t.references :opened_by_run, type: :uuid, null: false, foreign_key: { to_table: :lab_qc_runs }, index: false
      t.datetime :opened_at, null: false
      t.text :corrective_action
      t.references :corrective_action_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :corrective_action_at
      t.references :closed_by_run, type: :uuid, foreign_key: { to_table: :lab_qc_runs }, index: false
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :closed_at
      t.timestamps
    end
    add_index :lab_qc_blocks, %i[lab_instrument_id analyte_key], unique: true, where: "closed_at IS NULL", name: "idx_lab_qc_blocks_active"
    add_index :lab_qc_blocks, %i[lab_instrument_id opened_at], name: "idx_lab_qc_blocks_instrument"
    add_check_constraint :lab_qc_blocks, "(corrective_action IS NULL) = (corrective_action_at IS NULL)", name: "ck_lab_qc_blocks_action"
    add_check_constraint :lab_qc_blocks, "closed_at IS NULL OR (corrective_action IS NOT NULL AND closed_by_run_id IS NOT NULL)", name: "ck_lab_qc_blocks_closed"

    create_table :lab_qc_exceptions, id: :uuid do |t|
      t.references :lab_qc_block, type: :uuid, null: false, foreign_key: true, index: false
      t.references :lab_requisition_item, type: :uuid, null: false, foreign_key: true, index: true
      t.text :justification, null: false
      t.references :granted_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :granted_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :lab_qc_exceptions, %i[lab_qc_block_id lab_requisition_item_id], unique: true, name: "idx_lab_qc_exceptions_pair"

    create_table :lab_qc_review_items, id: :uuid do |t|
      t.references :lab_qc_block, type: :uuid, null: false, foreign_key: true, index: false
      t.references :lab_requisition_item, type: :uuid, null: false, foreign_key: true, index: true
      t.string :decision, null: false, default: "pending"
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :decided_at
      t.text :note
      t.timestamps
    end
    add_index :lab_qc_review_items, %i[lab_qc_block_id lab_requisition_item_id], unique: true, name: "idx_lab_qc_review_items_pair"
    add_index :lab_qc_review_items, :decision, where: "decision::text = 'pending'::text", name: "idx_lab_qc_review_items_pending"
    add_check_constraint :lab_qc_review_items, "decision::text = ANY (ARRAY['pending'::text, 'kept'::text, 'rectify'::text])", name: "ck_lab_qc_review_items_decision"
    add_check_constraint :lab_qc_review_items, "(decision::text = 'pending'::text) = (decided_at IS NULL)", name: "ck_lab_qc_review_items_decided"

    create_table :lab_eqa_rounds, id: :uuid do |t|
      t.references :exam_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.string :program, limit: 60, null: false
      t.string :round_code, limit: 40, null: false
      t.date :round_date, null: false
      t.jsonb :items, null: false
      t.references :annual_report_file, type: :uuid, foreign_key: { to_table: :exam_files }, index: { unique: true }
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :lab_eqa_rounds, %i[exam_provider_id program round_code], unique: true, name: "idx_lab_eqa_rounds_code"
    add_index :lab_eqa_rounds, %i[exam_provider_id round_date], name: "idx_lab_eqa_rounds_date"
    add_check_constraint :lab_eqa_rounds, "jsonb_typeof(items) = 'array' AND jsonb_array_length(items) BETWEEN 1 AND 60", name: "ck_lab_eqa_rounds_items"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")
end
