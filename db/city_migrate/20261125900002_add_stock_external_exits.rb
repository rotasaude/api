# Módulo 27b (BNAFAR; plano, Task 9; contrato §4; Q8, Q10, Q11, Q16): a saída
# externa e a base do desfazer da abertura.
#   - stock_external_exits: devolução, remanejamento, doação ou empréstimo
#     (S-DF, S-TR, S-D, S-E), com o destino (CNES de 7 dígitos ou CNPJ
#     alfanumérico) e o motivo cifrado (CityEncryption). Nunca some; só o tipo,
#     o destino e o motivo mudam, juntos, com `version` + 1 (Q8: a correção é da
#     saída inteira); a re-cifra regrava só o motivo;
#   - stock_external_exit_items: lote e quantidade inteira; só acréscimo; um
#     lote por saída;
#   - stock_movements: `stock_external_exit_id` como documento; os tipos
#     external_exit (−) e opening_reversal (−, Q10; documentado pela entrada
#     de abertura) entram em kind, sign e document;
#   - stock_openings: `reverted_at` e os três únicos passam a parciais
#     (`WHERE reverted_at IS NULL`), para reaplicar depois de desfeita.
# Triggers em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddStockExternalExits < ActiveRecord::Migration[8.1]
  # Espelhos de Bnafar::Catalog e Pharmacy::Catalog no dia desta migração (a
  # migração não lê código da aplicação: a lista do banco fica fixa).
  EXIT_TYPES = %w[S-DF S-TR S-D S-E].freeze
  MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return
                      vial_opening immunization immunization_reversal administration
                      vector_application vector_application_reversal
                      animal_vaccination animal_vaccination_reversal collar_placement
                      external_exit opening_reversal].freeze
  POSITIVE_KINDS = %w[opening receipt donation transfer_in return immunization_reversal vector_application_reversal
                      animal_vaccination_reversal].freeze
  NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry vial_opening immunization administration vector_application
                      animal_vaccination collar_placement external_exit opening_reversal].freeze
  ENTRY_KINDS = %w[opening receipt donation opening_reversal].freeze
  MAX_QUANTITY = "99999.99".freeze
  OPENING_INDEXES = {
    "idx_stock_openings_once" => %i[stock_location_id catalog_item_id],
    "idx_stock_openings_immunobiological_once" => %i[stock_location_id immunobiological_code],
    "idx_stock_openings_vector_product_once" => %i[stock_location_id vector_product_id]
  }.freeze

  def up
    create_exits
    change_movements
    change_openings

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_exits
    create_table :stock_external_exits, id: :uuid do |t|
      t.references :stock_location, type: :uuid, null: false, foreign_key: true, index: false
      t.string :exit_type, null: false
      t.string :destination_kind, null: false
      t.string :destination_code, null: false, limit: 14
      t.text :reason, null: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :recorded_at, null: false
      t.integer :version, null: false, default: 1
      t.datetime :created_at, null: false
    end
    add_index :stock_external_exits, %i[stock_location_id created_at id], name: "idx_stock_external_exits_location"
    add_check_constraint :stock_external_exits, "exit_type::text = ANY (ARRAY[#{quoted(EXIT_TYPES)}])", name: "ck_stock_external_exits_type"
    add_check_constraint :stock_external_exits,
                         "(destination_kind::text = 'cnes'::text AND destination_code::text ~ '^[0-9]{7}$'::text) OR " \
                         "(destination_kind::text = 'cnpj'::text AND destination_code::text ~ '^[0-9A-Z]{12}[0-9]{2}$'::text)",
                         name: "ck_stock_external_exits_destination"
    add_check_constraint :stock_external_exits, "version >= 1", name: "ck_stock_external_exits_version"

    create_table :stock_external_exit_items, id: :uuid do |t|
      t.references :stock_external_exit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stock_lot, type: :uuid, null: false, foreign_key: true, index: true
      t.integer :quantity, null: false
      t.datetime :created_at, null: false
    end
    add_index :stock_external_exit_items, %i[stock_external_exit_id stock_lot_id], unique: true, name: "idx_stock_external_exit_items_once"
    add_check_constraint :stock_external_exit_items, "quantity > 0 AND quantity <= 99999", name: "ck_stock_external_exit_items_quantity"
  end

  def change_movements
    add_reference :stock_movements, :stock_external_exit, type: :uuid, foreign_key: true, index: false
    add_index :stock_movements, :stock_external_exit_id, where: "stock_external_exit_id IS NOT NULL", name: "idx_stock_movements_external_exit"
    replace_check :stock_movements, "ck_stock_movements_kind", "kind::text = ANY (ARRAY[#{quoted(MOVEMENT_KINDS)}])"
    replace_check :stock_movements, "ck_stock_movements_sign",
                  "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY} AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(POSITIVE_KINDS)}]) OR quantity > 0::numeric) AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(NEGATIVE_KINDS)}]) OR quantity < 0::numeric)"
    replace_check :stock_movements, "ck_stock_movements_document",
                  "num_nonnulls(stock_entry_id, stock_transfer_id, dispensation_item_id, stock_adjustment_id, vial_opening_id, immunization_id, " \
                  "urgency_administration_id, vector_inspection_measure_id, rabies_vaccination_id, collar_id, stock_external_exit_id) = 1 AND " \
                  "(stock_entry_id IS NOT NULL) = (kind::text = ANY (ARRAY[#{quoted(ENTRY_KINDS)}])) AND " \
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
                  "(collar_id IS NOT NULL) = (kind::text = 'collar_placement'::text) AND " \
                  "(stock_external_exit_id IS NOT NULL) = (kind::text = 'external_exit'::text)"
  end

  def change_openings
    add_column :stock_openings, :reverted_at, :datetime
    OPENING_INDEXES.each do |name, columns|
      remove_index :stock_openings, name: name
      add_index :stock_openings, columns, unique: true, where: "reverted_at IS NULL", name: name
    end
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
