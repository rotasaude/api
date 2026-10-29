# Módulo 27a (ADR 0045): farmácia e almoxarifado. Papéis pharmacist,
# pharmacy_assistant e stock_keeper, vinculados a locais de estoque
# (stock_location_staff); o almoxarifado central (um só) e as farmácias de
# unidade (health_units.dispenses); parâmetros da cidade (uma linha, id 1,
# inserida aqui); mínimos por local e item; lotes CATMAT com validade; entradas
# (nota, doação, abertura uma vez por local e item); transferências em dois
# passos; ajustes com aprovação; receitas externas; dispensações. O saldo nunca
# é coluna: é a soma de stock_movements por (local, lote), só acréscimo, e o
# trigger recusa saldo negativo. `catalog_item_id` é o uuid do catálogo da
# plataforma (sem FK: outro banco). Toda quantidade numeric(12,2) até
# 99999.99 (contrato §13 H1/H12). Nenhuma coluna de antimicrobiano: a marca vem
# do catálogo da plataforma (H6/H12). Triggers em db/city_triggers.sql (o dump
# não representa trigger nem linha). Irreversível.
class AddPharmacyStock < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier exam_provider exam_regulator health_professional
             lab_releaser lab_staff municipal_admin pharmacist pharmacy_assistant protocol_author protocol_publisher protocol_reviewer
             stock_keeper surveillance viewer].freeze
  # Espelho de Pharmacy::Catalog no dia desta migração (a migração não lê
  # código da aplicação: a lista do banco fica fixa no que foi migrado).
  LOCATION_KINDS = %w[central unit].freeze
  STAFF_ROLES = %w[pharmacist pharmacy_assistant stock_keeper].freeze
  DISPENSER_ROLES = %w[pharmacist pharmacy_assistant].freeze
  MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return].freeze
  POSITIVE_KINDS = %w[opening receipt donation transfer_in return].freeze
  NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry].freeze
  ENTRY_KINDS = %w[invoice donation opening].freeze
  TRANSFER_STATUSES = %w[sent received received_with_difference].freeze
  ADJUSTMENT_KINDS = %w[adjustment loss expiry].freeze
  ADJUSTMENT_STATUSES = %w[applied pending approved rejected].freeze
  COUNCILS = %w[CRM CRO COREN].freeze
  DEFAULT_SETTINGS = { "common_validity_days" => 30, "continuous_validity_days" => 180, "continuous_interval_days" => 25,
                       "expiry_alert_days" => 90, "adjustment_approval_percent" => 10 }.freeze
  SETTING_RANGES = { "common_validity_days" => 1..365, "continuous_validity_days" => 1..365, "continuous_interval_days" => 1..90,
                     "expiry_alert_days" => 1..365, "adjustment_approval_percent" => 0..100 }.freeze
  MAX_QUANTITY = "99999.99".freeze
  PACKAGES = (1..10_000)

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"

    add_column :health_units, :dispenses, :boolean, null: false, default: false

    create_table :stock_locations, id: :uuid do |t|
      t.string :kind, null: false
      t.string :name, limit: 120, null: false
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :stock_locations, :health_unit_id, unique: true, where: "health_unit_id IS NOT NULL", name: "idx_stock_locations_unit"
    add_index :stock_locations, :kind, unique: true, where: "kind::text = 'central'::text", name: "idx_stock_locations_one_central"
    add_index :stock_locations, "lower((name)::text)", unique: true, name: "idx_stock_locations_name_ci"
    add_check_constraint :stock_locations, "kind::text = ANY (ARRAY[#{quoted(LOCATION_KINDS)}]::text[])", name: "ck_stock_locations_kind"
    add_check_constraint :stock_locations, "(kind::text = 'unit'::text) = (health_unit_id IS NOT NULL)", name: "ck_stock_locations_unit"

    create_table :stock_location_staff, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.string :role, null: false
      t.references :granted_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :granted_at, null: false
      t.datetime :revoked_at
      t.references :revoked_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
    end
    add_index :stock_location_staff, %i[stock_location_id user_id role], unique: true, where: "revoked_at IS NULL",
                                                                         name: "idx_stock_location_staff_active"
    add_index :stock_location_staff, :user_id, name: "idx_stock_location_staff_user"
    add_check_constraint :stock_location_staff, "role::text = ANY (ARRAY[#{quoted(STAFF_ROLES)}]::text[])", name: "ck_stock_location_staff_role"
    add_check_constraint :stock_location_staff, "(revoked_at IS NULL) = (revoked_by_user_id IS NULL)", name: "ck_stock_location_staff_revoked"

    create_table :pharmacy_settings, id: :smallint do |t|
      DEFAULT_SETTINGS.each_key { |key| t.integer key, null: false }
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :pharmacy_settings, "id = 1", name: "ck_pharmacy_settings_singleton"
    SETTING_RANGES.each do |key, range|
      add_check_constraint :pharmacy_settings, "#{key} >= #{Integer(range.min)} AND #{key} <= #{Integer(range.max)}",
                           name: "ck_pharmacy_settings_#{key}"
    end
    execute "INSERT INTO pharmacy_settings (id, #{DEFAULT_SETTINGS.keys.join(', ')}, updated_at) " \
            "VALUES (1, #{DEFAULT_SETTINGS.values.map { |v| Integer(v) }.join(', ')}, now()) ON CONFLICT (id) DO NOTHING"

    create_table :stock_minimums, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :catalog_item_id, null: false
      t.decimal :minimum, precision: 12, scale: 2, null: false
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :stock_minimums, %i[stock_location_id catalog_item_id], unique: true, name: "idx_stock_minimums_item"
    add_check_constraint :stock_minimums, "minimum >= 0::numeric AND minimum <= #{MAX_QUANTITY}", name: "ck_stock_minimums_minimum"

    create_table :stock_lots, id: :uuid do |t|
      t.uuid :catalog_item_id, null: false
      t.integer :catmat_code, null: false
      t.string :lot_number, limit: 40, null: false
      t.date :expires_on, null: false
      t.string :manufacturer, limit: 120
      t.string :dispensing_unit, limit: 20, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :stock_lots, %i[catalog_item_id lot_number], unique: true, name: "idx_stock_lots_number"
    add_index :stock_lots, :expires_on, name: "idx_stock_lots_expires_on"

    create_table :stock_entries, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :document_number, limit: 60
      t.string :supplier, limit: 120
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :stock_entries, "kind::text = ANY (ARRAY[#{quoted(ENTRY_KINDS)}]::text[])", name: "ck_stock_entries_kind"
    add_check_constraint :stock_entries, "kind::text = 'opening'::text OR (document_number IS NOT NULL AND supplier IS NOT NULL)",
                         name: "ck_stock_entries_document"

    create_table :stock_openings, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :catalog_item_id, null: false
      t.references :stock_entry, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :stock_openings, %i[stock_location_id catalog_item_id], unique: true, name: "idx_stock_openings_once"

    create_table :stock_transfers, id: :uuid do |t|
      t.references :from_location, type: :uuid, null: false, foreign_key: { to_table: :stock_locations }, index: false
      t.references :to_location, type: :uuid, null: false, foreign_key: { to_table: :stock_locations }, index: false
      t.string :status, null: false
      t.references :sent_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :sent_at, null: false
      t.references :received_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :received_at
      t.datetime :created_at, null: false
    end
    add_index :stock_transfers, %i[to_location_id status], name: "idx_stock_transfers_to_status"
    add_index :stock_transfers, %i[from_location_id created_at], name: "idx_stock_transfers_from_created"
    add_check_constraint :stock_transfers, "from_location_id <> to_location_id", name: "ck_stock_transfers_locations"
    add_check_constraint :stock_transfers, "status::text = ANY (ARRAY[#{quoted(TRANSFER_STATUSES)}]::text[])", name: "ck_stock_transfers_status"
    add_check_constraint :stock_transfers, "(status::text = 'sent'::text) = (received_at IS NULL)", name: "ck_stock_transfers_received"
    add_check_constraint :stock_transfers, "(received_at IS NULL) = (received_by_user_id IS NULL)", name: "ck_stock_transfers_receiver"

    create_table :stock_transfer_items, id: :uuid do |t|
      t.references :stock_transfer, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.decimal :quantity_sent, precision: 12, scale: 2, null: false
      t.decimal :quantity_received, precision: 12, scale: 2
      # Cifrado com a chave da cidade (CityEncryption::CITY_KEYED_TARGETS).
      t.text :difference_reason
    end
    add_index :stock_transfer_items, %i[stock_transfer_id stock_lot_id], unique: true, name: "idx_stock_transfer_items_lot"
    add_check_constraint :stock_transfer_items, "quantity_sent > 0::numeric AND quantity_sent <= #{MAX_QUANTITY}",
                         name: "ck_stock_transfer_items_sent"
    add_check_constraint :stock_transfer_items,
                         "quantity_received IS NULL OR (quantity_received >= 0::numeric AND quantity_received <= quantity_sent)",
                         name: "ck_stock_transfer_items_received"

    create_table :stock_adjustments, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :status, null: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.decimal :counted_quantity, precision: 12, scale: 2
      t.decimal :balance_at_request, precision: 12, scale: 2, null: false
      # reason e decision_reason cifrados com a chave da cidade.
      t.text :reason, null: false
      t.references :requested_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :decided_at
      t.text :decision_reason
      t.datetime :created_at, null: false
    end
    add_index :stock_adjustments, %i[stock_location_id status], name: "idx_stock_adjustments_location_status"
    add_check_constraint :stock_adjustments, "kind::text = ANY (ARRAY[#{quoted(ADJUSTMENT_KINDS)}]::text[])", name: "ck_stock_adjustments_kind"
    add_check_constraint :stock_adjustments, "status::text = ANY (ARRAY[#{quoted(ADJUSTMENT_STATUSES)}]::text[])",
                         name: "ck_stock_adjustments_status"
    add_check_constraint :stock_adjustments, "kind::text = 'adjustment'::text OR status::text = 'applied'::text",
                         name: "ck_stock_adjustments_approval"
    add_check_constraint :stock_adjustments, "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY}", name: "ck_stock_adjustments_quantity"
    add_check_constraint :stock_adjustments,
                         "(kind::text = 'adjustment'::text) = (counted_quantity IS NOT NULL) AND " \
                         "(counted_quantity IS NULL OR (counted_quantity >= 0::numeric AND counted_quantity <= #{MAX_QUANTITY}))",
                         name: "ck_stock_adjustments_counted"
    add_check_constraint :stock_adjustments, "balance_at_request >= 0::numeric AND balance_at_request <= #{MAX_QUANTITY}",
                         name: "ck_stock_adjustments_balance"
    add_check_constraint :stock_adjustments, "decided_by_user_id IS NULL OR decided_by_user_id <> requested_by_user_id",
                         name: "ck_stock_adjustments_decider"
    add_check_constraint :stock_adjustments,
                         "(status::text = ANY (ARRAY['approved'::text, 'rejected'::text])) = (decided_at IS NOT NULL)",
                         name: "ck_stock_adjustments_decided"

    create_table :external_prescriptions, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.string :prescriber_name, limit: 120, null: false
      t.string :council, null: false
      t.string :council_state, limit: 2, null: false
      t.string :council_number, limit: 10, null: false
      t.date :issued_on, null: false
      # Cifrado com a chave da cidade.
      t.text :notification_number
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :external_prescriptions, :patient_id, name: "idx_external_prescriptions_patient"
    add_check_constraint :external_prescriptions, "council::text = ANY (ARRAY[#{quoted(COUNCILS)}]::text[])",
                         name: "ck_external_prescriptions_council"
    add_check_constraint :external_prescriptions, "council_state::text ~ '^[A-Z]{2}$'::text", name: "ck_external_prescriptions_council_state"
    add_check_constraint :external_prescriptions, "council_number::text ~ '^[0-9]{1,10}$'::text",
                         name: "ck_external_prescriptions_council_number"

    create_table :external_prescription_items, id: :uuid do |t|
      t.references :external_prescription, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.uuid :catalog_item_id, null: false
      t.integer :catmat_code, null: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.string :quantity_unit, limit: 30, null: false
      # Cifrado com a chave da cidade.
      t.text :dosage_instructions, null: false
      t.boolean :continuous, null: false, default: false
      # Retrato da lista de controle do catálogo no registro.
      t.string :controlled_list, limit: 3
    end
    add_index :external_prescription_items, %i[external_prescription_id position], unique: true,
                                                                                   name: "idx_external_prescription_items_position"
    add_check_constraint :external_prescription_items, "position >= 1", name: "ck_external_prescription_items_position"
    add_check_constraint :external_prescription_items, "quantity > 0::numeric AND quantity <= #{MAX_QUANTITY}",
                         name: "ck_external_prescription_items_quantity"

    create_table :dispensations, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :clinical_document, type: :uuid, foreign_key: true, index: false
      t.references :external_prescription, type: :uuid, foreign_key: true, index: false
      t.references :dispensed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :dispensed_by_role, null: false
      t.datetime :dispensed_at, null: false
      t.boolean :retained, null: false, default: false
      # Cifrado com a chave da cidade.
      t.text :notification_number
      t.datetime :created_at, null: false
    end
    add_index :dispensations, %i[patient_id dispensed_at], name: "idx_dispensations_patient"
    add_index :dispensations, :clinical_document_id, name: "idx_dispensations_clinical_document"
    add_index :dispensations, :external_prescription_id, name: "idx_dispensations_external_prescription"
    add_check_constraint :dispensations, "num_nonnulls(clinical_document_id, external_prescription_id) = 1",
                         name: "ck_dispensations_prescription"
    add_check_constraint :dispensations, "dispensed_by_role::text = ANY (ARRAY[#{quoted(DISPENSER_ROLES)}]::text[])",
                         name: "ck_dispensations_role"
    add_check_constraint :dispensations, "notification_number IS NULL OR retained", name: "ck_dispensations_retention"

    create_table :dispensation_items, id: :uuid do |t|
      t.references :dispensation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :prescription_item, type: :uuid, foreign_key: true, index: false
      t.references :external_prescription_item, type: :uuid, foreign_key: true, index: false
      t.uuid :catalog_item_id, null: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.boolean :mapped_from_free_text, null: false, default: false
      t.boolean :completes_item, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_index :dispensation_items, :dispensation_id, name: "idx_dispensation_items_dispensation"
    add_index :dispensation_items, :prescription_item_id, name: "idx_dispensation_items_prescription_item"
    add_index :dispensation_items, :external_prescription_item_id, name: "idx_dispensation_items_external_item"
    add_check_constraint :dispensation_items, "num_nonnulls(prescription_item_id, external_prescription_item_id) = 1",
                         name: "ck_dispensation_items_source"
    add_check_constraint :dispensation_items, "quantity > 0::numeric AND quantity <= #{MAX_QUANTITY}", name: "ck_dispensation_items_quantity"
    add_check_constraint :dispensation_items, "NOT mapped_from_free_text OR prescription_item_id IS NOT NULL",
                         name: "ck_dispensation_items_free_text"

    create_table :stock_movements, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :catalog_item_id, null: false
      t.string :kind, null: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.references :stock_entry, type: :uuid, foreign_key: true, index: false
      t.references :stock_transfer, type: :uuid, foreign_key: true, index: false
      t.references :dispensation_item, type: :uuid, foreign_key: true, index: false
      t.references :stock_adjustment, type: :uuid, foreign_key: true, index: false
      # Cifrado com a chave da cidade.
      t.text :reason
      t.integer :package_units
      t.integer :packages
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :recorded_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :stock_movements, %i[stock_location_id stock_lot_id], name: "idx_stock_movements_balance"
    add_index :stock_movements, %i[stock_lot_id recorded_at id], name: "idx_stock_movements_lot_time"
    add_index :stock_movements, :dispensation_item_id, name: "idx_stock_movements_dispensation_item"
    add_check_constraint :stock_movements, "kind::text = ANY (ARRAY[#{quoted(MOVEMENT_KINDS)}]::text[])", name: "ck_stock_movements_kind"
    add_check_constraint :stock_movements,
                         "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY} AND " \
                         "(kind::text <> ALL (ARRAY[#{quoted(POSITIVE_KINDS)}]::text[]) OR quantity > 0::numeric) AND " \
                         "(kind::text <> ALL (ARRAY[#{quoted(NEGATIVE_KINDS)}]::text[]) OR quantity < 0::numeric)",
                         name: "ck_stock_movements_sign"
    # Um documento por movimento, e o do tipo: entrada ⇔ opening/receipt/
    # donation; item de dispensação ⇔ dispensing/return; transferência só em
    # transfer_out/transfer_in (obrigatória) ou loss (a diferença do
    # recebimento); ajuste só em adjustment/expiry (obrigatório) ou loss.
    add_check_constraint :stock_movements,
                         "num_nonnulls(stock_entry_id, stock_transfer_id, dispensation_item_id, stock_adjustment_id) = 1 AND " \
                         "(stock_entry_id IS NOT NULL) = (kind::text = ANY (ARRAY['opening'::text, 'receipt'::text, 'donation'::text])) AND " \
                         "(dispensation_item_id IS NOT NULL) = (kind::text = ANY (ARRAY['dispensing'::text, 'return'::text])) AND " \
                         "(stock_transfer_id IS NULL OR kind::text = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'loss'::text])) AND " \
                         "(stock_adjustment_id IS NULL OR kind::text = ANY (ARRAY['adjustment'::text, 'expiry'::text, 'loss'::text])) AND " \
                         "(kind::text <> ALL (ARRAY['transfer_out'::text, 'transfer_in'::text]) OR stock_transfer_id IS NOT NULL) AND " \
                         "(kind::text <> ALL (ARRAY['adjustment'::text, 'expiry'::text]) OR stock_adjustment_id IS NOT NULL)",
                         name: "ck_stock_movements_document"
    add_check_constraint :stock_movements,
                         "kind::text <> ALL (ARRAY['loss'::text, 'expiry'::text, 'adjustment'::text, 'return'::text]) OR reason IS NOT NULL",
                         name: "ck_stock_movements_reason"
    add_check_constraint :stock_movements,
                         "(package_units IS NULL) = (packages IS NULL) AND (package_units IS NULL OR " \
                         "(package_units >= #{PACKAGES.min} AND package_units <= #{PACKAGES.max} AND " \
                         "packages >= #{PACKAGES.min} AND packages <= #{PACKAGES.max}))",
                         name: "ck_stock_movements_package"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
