# Tokens de serviço da API de manutenção (spec §7), no banco de PLATAFORMA.
# Só o digest é guardado: o segredo em claro existe uma vez, na resposta da
# mutation que o cria.
class CreateMaintenanceTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :maintenance_tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid     :maintainer_id, null: false
      t.string   :name, null: false
      t.string   :token_digest, null: false
      t.string   :token_prefix, null: false
      t.string   :access, null: false
      t.string   :city_slugs, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.string   :last_used_ip
      t.timestamps
      t.index :token_digest, unique: true
      t.index :maintainer_id
      t.check_constraint "access IN ('read', 'read_write')", name: "ck_maintenance_tokens_access"
    end
  end
end
