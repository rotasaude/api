# Solid Cache no banco de PLATAFORMA (Plano 5, decisão do usuário): rate_limit dos
# logins e cache de protocolos (a chave carrega o shard da cidade). Transcrito de
# db/cache_schema.rb. Aditiva.
class CreateSolidCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :solid_cache_entries do |t|
      t.binary :key, null: false
      t.binary :value, null: false
      t.datetime :created_at, null: false
      t.bigint :key_hash, null: false
      t.integer :byte_size, null: false
      t.index :byte_size, name: "index_solid_cache_entries_on_byte_size"
      t.index %i[key_hash byte_size], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
      t.index :key_hash, name: "index_solid_cache_entries_on_key_hash", unique: true
    end
  end
end
