# Módulo 24b (ADR 0052): aparelho de campo e sincronização v1. O token do aparelho
# (`rsf_` + 32 bytes) nunca é guardado: só o SHA-256 (hex, 64, único), no padrão do
# `lab_middleware_tokens`. O aparelho só muda `last_used_at` e, uma vez, as três
# colunas de revogação (`revoked_*`, de NULL a valor); nada se apaga. O livro de
# idempotência (`field_sync_receipts`, um `client_uuid` por item aceito) e as
# lápides de remoção (`field_sync_tombstones`) são só acréscimo. A visita e a
# atividade coletiva ganham a FK `field_device_id` (a coluna nasceu nas 900001 e
# 900002). Triggers em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddFieldDevices < ActiveRecord::Migration[8.1]
  # Espelho de FieldSync::Catalog e HomeVisits::Catalog no dia desta migração (a
  # migração não lê código da aplicação).
  ITEM_TYPES = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration].freeze
  REVOKED_REASONS = %w[user admin membership_ended user_disabled].freeze
  ENTITY_TYPES = %w[household registration].freeze
  TOMBSTONE_REASONS = %w[moved erased].freeze

  def up
    create_devices
    create_receipts
    create_tombstones
    add_foreign_key :home_visits, :field_devices
    add_foreign_key :collective_activities, :field_devices
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_devices
    create_table :field_devices, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.references :professional, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.string :token_digest, limit: 64, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.references :revoked_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.string :revoked_reason
      t.datetime :created_at, null: false
    end
    add_index :field_devices, :token_digest, unique: true
    add_index :field_devices, :user_id, where: "revoked_at IS NULL", name: "idx_field_devices_active_by_user"
    add_check_constraint :field_devices, "(token_digest)::text ~ '^[0-9a-f]{64}$'::text", name: "ck_field_devices_token_digest"
    add_check_constraint :field_devices, "length(btrim((name)::text)) >= 1 AND length(btrim((name)::text)) <= 60",
                         name: "ck_field_devices_name"
    add_check_constraint :field_devices, "revoked_reason IS NULL OR #{varchar_in('revoked_reason', REVOKED_REASONS)}",
                         name: "ck_field_devices_revoked_reason"
    add_check_constraint :field_devices, "(revoked_at IS NULL) = (revoked_reason IS NULL)", name: "ck_field_devices_revoked"
    add_check_constraint :field_devices,
                         "revoked_by_user_id IS NULL OR (revoked_reason)::text = ANY (ARRAY['admin'::character varying::text, 'user'::character varying::text])",
                         name: "ck_field_devices_revoked_by"
  end

  def create_receipts
    create_table :field_sync_receipts, id: :uuid do |t|
      t.uuid :client_uuid, null: false
      t.references :field_device, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.string :item_type, null: false
      t.string :result_type, null: false
      t.uuid :result_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :field_sync_receipts, :client_uuid, unique: true, name: "idx_field_sync_receipts_client_uuid"
    add_check_constraint :field_sync_receipts, varchar_in("item_type", ITEM_TYPES), name: "ck_field_sync_receipts_item_type"
  end

  def create_tombstones
    create_table :field_sync_tombstones, id: :uuid do |t|
      t.string :entity_type, null: false
      t.uuid :entity_id, null: false
      t.references :micro_area, type: :uuid, null: false, foreign_key: true, index: false
      t.string :reason, null: false
      t.datetime :created_at, null: false
    end
    add_index :field_sync_tombstones, %i[micro_area_id created_at], name: "idx_field_sync_tombstones_micro_area"
    add_check_constraint :field_sync_tombstones, varchar_in("entity_type", ENTITY_TYPES), name: "ck_field_sync_tombstones_entity_type"
    add_check_constraint :field_sync_tombstones, varchar_in("reason", TOMBSTONE_REASONS), name: "ck_field_sync_tombstones_reason"
  end

  # varchar IN (...) como o PG16 o devolve (e como o dump o grava).
  def varchar_in(column, list) = "(#{column})::text = ANY (ARRAY[#{list.map { |item| "'#{item}'::character varying::text" }.join(', ')}])"
end
