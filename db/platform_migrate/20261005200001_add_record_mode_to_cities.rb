# ADR 0028 (spec 2026-10-05 §3): modo de prontuário e endereço do PEC por
# cidade, e os interruptores por cidade. O IBGE NÃO nasce aqui: a fonte única é
# city_profile.ibge_code, no banco da cidade (contratos §3). Só expansão. A
# chave do interruptor é conferida contra o catálogo em código
# (Platform::Features::CATALOG), não por CHECK: chave nova não pede migração.
class AddRecordModeToCities < ActiveRecord::Migration[8.1]
  RECORD_MODES = %w[off integrated record].freeze

  # Forma que o Postgres devolve igual ao reler o próprio texto (api#38).
  def self.record_mode_check
    "record_mode::text = ANY (ARRAY[#{RECORD_MODES.map { |m| "'#{m}'::text" }.join(', ')}])"
  end

  def change
    add_column :cities, :record_mode, :string, null: false, default: "off"
    add_column :cities, :pec_url, :string, limit: 255
    add_check_constraint :cities, self.class.record_mode_check, name: "ck_cities_record_mode"
    add_check_constraint :cities, "pec_url IS NULL OR pec_url::text ~ '^https://'::text", name: "ck_cities_pec_url_https"

    create_table :city_features, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :city_id, null: false
      t.string :key, null: false
      t.boolean :enabled, null: false, default: false
      t.uuid :changed_by_maintainer_id, null: false
      t.datetime :changed_at, null: false
      t.timestamps
      t.index %i[city_id key], unique: true, name: "idx_city_features_city_key"
    end
    add_foreign_key :city_features, :cities
    add_foreign_key :city_features, :maintainers, column: :changed_by_maintainer_id
  end
end
