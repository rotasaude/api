# Módulo 24c (ADR 0053; contrato §3.1, Q30, Q31): o mapa offline por município.
#   - field_maps: uma linha por cidade. `state` descreve a ÚLTIMA geração
#     (building | ready | failed, com `error_code` só no failed); o ARQUIVO
#     PUBLICADO (version, size_bytes, sha256, storage_key, built_at) é tudo ou
#     nada e continua servido enquanto a geração nova roda ou falha.
#   - field_map_bases: a base de onde os recortes saem (uma por versão; o
#     arquivo só existe na `ready`).
# O arquivo mora no serviço do Active Storage, por chave; aqui só o endereço e
# o resumo. Nenhum dado de pessoa. Irreversível.
class CreateFieldMaps < ActiveRecord::Migration[8.1]
  # Espelho de FieldMaps::Catalog no dia desta migração (a migração não lê
  # código da aplicação).
  STATES = %w[building ready failed].freeze
  ERROR_CODES = %w[base_missing extract_failed boundary_missing].freeze
  BASE_STATES = %w[copying ready failed].freeze
  SHA256 = "'^[0-9a-f]{64}$'".freeze

  def up
    create_table :field_maps, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :city_id, null: false
      t.string :state, null: false
      t.string :error_code
      t.date :version
      t.bigint :size_bytes
      t.string :sha256, limit: 64
      t.string :storage_key
      t.datetime :built_at
      t.datetime :requested_at, null: false
      t.timestamps
      t.index :city_id, unique: true, name: "idx_field_maps_city"
      t.check_constraint text_in("state", STATES), name: "ck_field_maps_state"
      t.check_constraint "(error_code IS NULL OR #{text_in('error_code', ERROR_CODES)}) AND ((state = 'failed') = (error_code IS NOT NULL))",
                         name: "ck_field_maps_error"
      t.check_constraint "(version IS NULL AND size_bytes IS NULL AND sha256 IS NULL AND storage_key IS NULL AND built_at IS NULL) OR " \
                         "(version IS NOT NULL AND size_bytes IS NOT NULL AND size_bytes > 0 AND sha256 IS NOT NULL AND storage_key IS NOT NULL AND built_at IS NOT NULL)",
                         name: "ck_field_maps_published"
      t.check_constraint "sha256 IS NULL OR sha256 ~ #{SHA256}", name: "ck_field_maps_sha256"
    end
    add_foreign_key :field_maps, :cities

    create_table :field_map_bases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.date :version, null: false
      t.string :state, null: false
      t.string :error_code
      t.string :source_url, null: false
      t.string :storage_key
      t.bigint :size_bytes
      t.string :sha256, limit: 64
      t.datetime :ready_at
      t.timestamps
      t.index :version, unique: true, name: "idx_field_map_bases_version"
      t.check_constraint text_in("state", BASE_STATES), name: "ck_field_map_bases_state"
      t.check_constraint "(error_code IS NULL OR #{text_in('error_code', ERROR_CODES)}) AND ((state = 'failed') = (error_code IS NOT NULL))",
                         name: "ck_field_map_bases_error"
      t.check_constraint "(state = 'ready' AND storage_key IS NOT NULL AND size_bytes IS NOT NULL AND size_bytes > 0 AND sha256 IS NOT NULL AND ready_at IS NOT NULL) OR " \
                         "(state <> 'ready' AND storage_key IS NULL AND size_bytes IS NULL AND sha256 IS NULL AND ready_at IS NULL)",
                         name: "ck_field_map_bases_ready"
      t.check_constraint "sha256 IS NULL OR sha256 ~ #{SHA256}", name: "ck_field_map_bases_sha256"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def text_in(column, list) = "#{column} IN (#{list.map { |item| "'#{item}'" }.join(', ')})"
end
