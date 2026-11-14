# Módulo 24c (ADR 0053): coordenada do imóvel e da visita, e os acréscimos do
# livro de idempotência e do aparelho de campo.
#   - household_versions.location e home_visits.location: JSON cifrado com a
#     chave da cidade ({ latitude, longitude, accuracy_m?, source }), nulos. A
#     versão do domicílio e a visita não mudam a coordenada depois de gravadas;
#     a re-cifra passa (triggers em db/city_triggers.sql).
#   - field_sync_receipts: item `family` e `result_version` (a versão que o
#     registro ficou naquele recebimento; nula nos recibos anteriores e nos
#     tipos sem versão).
#   - field_devices: motivo de revogação `replaced` (substituição do aparelho,
#     com autor; Q17).
# O dump não representa trigger. Irreversível.
class AddFieldLocations < ActiveRecord::Migration[8.1]
  # Espelho de FieldSync::Catalog no dia desta migração (a migração não lê
  # código da aplicação).
  ITEM_TYPES = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration family].freeze
  REVOKED_REASONS = %w[user admin replaced membership_ended user_disabled].freeze
  REVOKED_WITH_AUTHOR = %w[admin user replaced].freeze

  def up
    add_column :household_versions, :location, :text
    add_column :home_visits, :location, :text

    add_column :field_sync_receipts, :result_version, :integer
    add_check_constraint :field_sync_receipts, "result_version IS NULL OR result_version >= 1",
                         name: "ck_field_sync_receipts_result_version"
    remove_check_constraint :field_sync_receipts, name: "ck_field_sync_receipts_item_type"
    add_check_constraint :field_sync_receipts, varchar_in("item_type", ITEM_TYPES), name: "ck_field_sync_receipts_item_type"

    remove_check_constraint :field_devices, name: "ck_field_devices_revoked_reason"
    add_check_constraint :field_devices, "revoked_reason IS NULL OR #{varchar_in('revoked_reason', REVOKED_REASONS)}",
                         name: "ck_field_devices_revoked_reason"
    remove_check_constraint :field_devices, name: "ck_field_devices_revoked_by"
    add_check_constraint :field_devices, "revoked_by_user_id IS NULL OR #{varchar_in('revoked_reason', REVOKED_WITH_AUTHOR)}",
                         name: "ck_field_devices_revoked_by"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # varchar IN (...) como o PG16 o devolve (e como o dump o grava).
  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{list.map { |item| "'#{item}'::character varying::text" }.join(', ')}])"
end
