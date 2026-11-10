# Módulo 32b (ADR 0050; contrato §5 e §12 Q4/Q5; plano, Desvio 2): a prescrição
# e a checagem de medicação da observação da UPA. A prescrição vive em versões
# (a nova aponta a anterior; no máximo uma `active` por encontro) e o status só
# anda para frente; os itens e as administrações são só acréscimo (a re-cifra
# regrava as colunas cifradas). Cifrados (chave da cidade): `suspension_reason`,
# `instructions` e `reason`. O catálogo é da plataforma: `catalog_item_id` sem
# FK. Triggers em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddUrgencyPrescriptions < ActiveRecord::Migration[8.1]
  # Espelhos de Urgency::Catalog e PrescriptionItem no dia desta migração (a
  # migração não lê código da aplicação).
  PRESCRIPTION_STATUSES = %w[active superseded suspended ended].freeze
  FREQUENCY_KINDS = %w[once interval if_needed].freeze
  DOSE_UNITS = %w[mg mcg g mL UI mEq gota comprimido capsula ampola frasco jato aplicacao sache].freeze
  ROUTES = %w[oral sublingual topical ophthalmic otic nasal inhalation vaginal rectal intramuscular intravenous
              subcutaneous other].freeze
  ADMINISTRATION_STATUSES = %w[administered not_administered refused].freeze

  def up
    create_table :urgency_prescriptions, id: :uuid do |t|
      t.references :urgency_encounter, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.string :status, null: false, default: "active"
      t.references :supersedes, type: :uuid, foreign_key: { to_table: :urgency_prescriptions }, index: false
      t.references :prescribed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :professional_link, type: :uuid, null: false, foreign_key: true, index: false
      t.string :cbo_code, limit: 6, null: false
      t.datetime :prescribed_at, null: false
      t.text :suspension_reason
      t.datetime :status_changed_at
      t.references :status_changed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :urgency_prescriptions, %i[urgency_encounter_id version], unique: true, name: "idx_urgency_prescriptions_version"
    add_index :urgency_prescriptions, :urgency_encounter_id, unique: true, where: "status = 'active'",
                                                             name: "idx_urgency_prescriptions_active"
    add_check_constraint :urgency_prescriptions, "status::text = ANY (ARRAY[#{quoted(PRESCRIPTION_STATUSES)}]::text[])",
                         name: "ck_urgency_prescriptions_status"
    add_check_constraint :urgency_prescriptions, "version >= 1 AND (version = 1) = (supersedes_id IS NULL)",
                         name: "ck_urgency_prescriptions_version"
    add_check_constraint :urgency_prescriptions, "(status::text = 'suspended') = (suspension_reason IS NOT NULL)",
                         name: "ck_urgency_prescriptions_suspended"
    add_check_constraint :urgency_prescriptions,
                         "(status::text = 'active') = (status_changed_at IS NULL) AND " \
                         "(status_changed_at IS NULL) = (status_changed_by_user_id IS NULL)",
                         name: "ck_urgency_prescriptions_closing"

    create_table :urgency_prescription_items, id: :uuid do |t|
      t.references :urgency_prescription, type: :uuid, null: false, foreign_key: true, index: false
      t.column :position, :smallint, null: false
      t.uuid :catalog_item_id, null: false
      t.integer :catmat_code, null: false
      t.string :controlled_list, limit: 3
      t.decimal :dose, precision: 10, scale: 3, null: false
      t.string :dose_unit, limit: 20, null: false
      t.string :route, limit: 20, null: false
      t.string :frequency_kind, null: false
      t.column :interval_hours, :smallint
      t.column :max_per_day, :smallint
      t.datetime :first_dose_at, null: false
      t.text :instructions
      t.decimal :stock_quantity_per_dose, precision: 12, scale: 2, null: false, default: 1
      t.string :stock_unit, limit: 20, null: false
      t.datetime :created_at, null: false
    end
    add_index :urgency_prescription_items, %i[urgency_prescription_id position], unique: true,
                                                                                 name: "idx_urgency_prescription_items_position"
    add_index :urgency_prescription_items, :catalog_item_id, name: "idx_urgency_prescription_items_catalog"
    add_check_constraint :urgency_prescription_items, "\"position\" BETWEEN 1 AND 20", name: "ck_urgency_prescription_items_position"
    add_check_constraint :urgency_prescription_items, "dose > 0", name: "ck_urgency_prescription_items_dose"
    add_check_constraint :urgency_prescription_items, "dose_unit::text = ANY (ARRAY[#{quoted(DOSE_UNITS)}]::text[])",
                         name: "ck_urgency_prescription_items_dose_unit"
    add_check_constraint :urgency_prescription_items, "route::text = ANY (ARRAY[#{quoted(ROUTES)}]::text[])",
                         name: "ck_urgency_prescription_items_route"
    add_check_constraint :urgency_prescription_items, "frequency_kind::text = ANY (ARRAY[#{quoted(FREQUENCY_KINDS)}]::text[])",
                         name: "ck_urgency_prescription_items_frequency_kind"
    add_check_constraint :urgency_prescription_items, "(frequency_kind::text = 'interval') = (interval_hours IS NOT NULL)",
                         name: "ck_urgency_prescription_items_interval_pair"
    add_check_constraint :urgency_prescription_items, "interval_hours IS NULL OR interval_hours BETWEEN 1 AND 24",
                         name: "ck_urgency_prescription_items_interval_range"
    add_check_constraint :urgency_prescription_items, "(frequency_kind::text = 'if_needed') = (max_per_day IS NOT NULL)",
                         name: "ck_urgency_prescription_items_max_pair"
    add_check_constraint :urgency_prescription_items, "max_per_day IS NULL OR max_per_day BETWEEN 1 AND 24",
                         name: "ck_urgency_prescription_items_max_range"
    add_check_constraint :urgency_prescription_items, "stock_quantity_per_dose > 0 AND stock_quantity_per_dose <= 99999.99",
                         name: "ck_urgency_prescription_items_stock_quantity"

    create_table :urgency_administrations, id: :uuid do |t|
      t.references :urgency_prescription_item, type: :uuid, null: false, foreign_key: true, index: false
      t.references :urgency_encounter, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :scheduled_at
      t.string :status, null: false
      t.text :reason
      t.datetime :administered_at
      t.references :stock_lot, type: :uuid, foreign_key: true, index: false
      t.decimal :stock_quantity, precision: 12, scale: 2
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :professional_link, type: :uuid, null: false, foreign_key: true, index: false
      t.string :cbo_code, limit: 6, null: false
      t.datetime :recorded_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :urgency_administrations, %i[urgency_prescription_item_id scheduled_at], unique: true, where: "scheduled_at IS NOT NULL",
                                                                                       name: "idx_urgency_administrations_slot"
    add_index :urgency_administrations, %i[urgency_encounter_id recorded_at], name: "idx_urgency_administrations_encounter"
    add_index :urgency_administrations, %i[urgency_prescription_item_id administered_at], name: "idx_urgency_administrations_item"
    add_check_constraint :urgency_administrations, "status::text = ANY (ARRAY[#{quoted(ADMINISTRATION_STATUSES)}]::text[])",
                         name: "ck_urgency_administrations_status"
    add_check_constraint :urgency_administrations, "(status::text = 'administered') = (administered_at IS NOT NULL)",
                         name: "ck_urgency_administrations_administered_at"
    add_check_constraint :urgency_administrations, "(status::text = 'administered') = (reason IS NULL)",
                         name: "ck_urgency_administrations_reason"
    add_check_constraint :urgency_administrations, "(stock_lot_id IS NULL) = (stock_quantity IS NULL)",
                         name: "ck_urgency_administrations_stock_pair"
    add_check_constraint :urgency_administrations, "stock_lot_id IS NULL OR status::text = 'administered'",
                         name: "ck_urgency_administrations_stock_status"
    add_check_constraint :urgency_administrations, "stock_quantity IS NULL OR stock_quantity > 0",
                         name: "ck_urgency_administrations_stock_quantity"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")
end
