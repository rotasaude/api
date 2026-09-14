# Identidade da cidade DENTRO do banco dela (spec banco-por-cidade §3): nome, UF,
# código IBGE e settings, gravados no provisionamento (Plano 4). Um dump
# restaurado sozinho continua sabendo de que cidade é, sem ler o catálogo.
#
# Singleton: a coluna `singleton` só aceita true e é única — no máximo uma linha.
# Migração aditiva (expand-only).
class CreateCityProfile < ActiveRecord::Migration[8.1]
  def change
    create_table :city_profile, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean :singleton, null: false, default: true
      t.string :name, null: false
      t.string :uf, limit: 2
      t.string :ibge_code, limit: 7
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end
    add_index :city_profile, :singleton, unique: true, name: "index_city_profile_singleton"
    add_check_constraint :city_profile, "singleton", name: "ck_city_profile_singleton"
  end
end
