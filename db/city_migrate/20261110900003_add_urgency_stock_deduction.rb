# Módulo 32b (ADR 0050, contrato §1 e §6: o mesmo caminho do 29, Desvio 7): a
# baixa do estoque pela checagem da UPA. O livro do 27a ganha o movimento
# `administration` (negativo) com a administração por documento
# (`stock_movements.urgency_administration_id`), e nasce
# `urgency_stock_shortfalls` (R7): a falta registrada quando a baixa não pôde
# acontecer (sem local, saldo insuficiente, lote indisponível). A falta aberta
# só recebe a conciliação (uma vez); a nota é cifrada com a chave da cidade
# (a re-cifra passa antes de tudo). O catálogo é da plataforma:
# `catalog_item_id` sem FK. Triggers em db/city_triggers.sql (o dump não
# representa trigger). Irreversível.
class AddUrgencyStockDeduction < ActiveRecord::Migration[8.1]
  # Espelhos de Pharmacy::Catalog e Urgency::Catalog no dia desta migração (a
  # migração não lê código da aplicação).
  MOVEMENT_KINDS = %w[opening receipt donation transfer_out transfer_in dispensing loss expiry adjustment return
                      vial_opening immunization immunization_reversal administration].freeze
  POSITIVE_KINDS = %w[opening receipt donation transfer_in return immunization_reversal].freeze
  NEGATIVE_KINDS = %w[transfer_out dispensing loss expiry vial_opening immunization administration].freeze
  SHORTFALL_CAUSES = %w[no_location insufficient_balance lot_unavailable].freeze
  MAX_QUANTITY = "99999.99".freeze

  def up
    change_stock_movements
    create_shortfalls
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def change_stock_movements
    add_reference :stock_movements, :urgency_administration, type: :uuid, foreign_key: true, index: false
    add_index :stock_movements, :urgency_administration_id, name: "idx_stock_movements_urgency_administration"
    replace_check :stock_movements, "ck_stock_movements_kind", "kind::text = ANY (ARRAY[#{quoted(MOVEMENT_KINDS)}]::text[])"
    replace_check :stock_movements, "ck_stock_movements_sign",
                  "quantity <> 0::numeric AND abs(quantity) <= #{MAX_QUANTITY} AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(POSITIVE_KINDS)}]::text[]) OR quantity > 0::numeric) AND " \
                  "(kind::text <> ALL (ARRAY[#{quoted(NEGATIVE_KINDS)}]::text[]) OR quantity < 0::numeric)"
    replace_check :stock_movements, "ck_stock_movements_document",
                  "num_nonnulls(stock_entry_id, stock_transfer_id, dispensation_item_id, stock_adjustment_id, vial_opening_id, immunization_id, urgency_administration_id) = 1 AND " \
                  "(stock_entry_id IS NOT NULL) = (kind::text = ANY (ARRAY['opening'::text, 'receipt'::text, 'donation'::text])) AND " \
                  "(dispensation_item_id IS NOT NULL) = (kind::text = ANY (ARRAY['dispensing'::text, 'return'::text])) AND " \
                  "(stock_transfer_id IS NULL OR kind::text = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'loss'::text])) AND " \
                  "(stock_adjustment_id IS NULL OR kind::text = ANY (ARRAY['adjustment'::text, 'expiry'::text, 'loss'::text])) AND " \
                  "(kind::text <> ALL (ARRAY['transfer_out'::text, 'transfer_in'::text]) OR stock_transfer_id IS NOT NULL) AND " \
                  "(kind::text <> ALL (ARRAY['adjustment'::text, 'expiry'::text]) OR stock_adjustment_id IS NOT NULL) AND " \
                  "(vial_opening_id IS NOT NULL) = (kind::text = 'vial_opening'::text) AND " \
                  "(immunization_id IS NOT NULL) = (kind::text = ANY (ARRAY['immunization'::text, 'immunization_reversal'::text])) AND " \
                  "(urgency_administration_id IS NOT NULL) = (kind::text = 'administration'::text)"
  end

  def create_shortfalls
    create_table :urgency_stock_shortfalls, id: :uuid do |t|
      t.references :urgency_administration, type: :uuid, null: false, foreign_key: true, index: { unique: true, name: "idx_urgency_stock_shortfalls_administration" }
      t.references :stock_location, type: :uuid, foreign_key: true, index: false
      t.uuid :catalog_item_id, null: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.string :cause, null: false
      t.datetime :reconciled_at
      t.references :reconciled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :reconciliation_note
      t.timestamps
    end
    add_index :urgency_stock_shortfalls, %i[stock_location_id reconciled_at created_at], name: "idx_urgency_stock_shortfalls_location"
    add_check_constraint :urgency_stock_shortfalls, "cause::text = ANY (ARRAY[#{quoted(SHORTFALL_CAUSES)}]::text[])",
                         name: "ck_urgency_stock_shortfalls_cause"
    add_check_constraint :urgency_stock_shortfalls, "quantity > 0", name: "ck_urgency_stock_shortfalls_quantity"
    add_check_constraint :urgency_stock_shortfalls, "(cause::text = 'no_location'::text) = (stock_location_id IS NULL)",
                         name: "ck_urgency_stock_shortfalls_location"
    add_check_constraint :urgency_stock_shortfalls,
                         "(reconciled_at IS NULL) = (reconciled_by_user_id IS NULL) AND (reconciled_at IS NULL) = (reconciliation_note IS NULL)",
                         name: "ck_urgency_stock_shortfalls_reconciliation"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
