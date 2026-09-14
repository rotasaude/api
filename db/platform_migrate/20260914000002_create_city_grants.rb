# Grants assinados de entrada numa cidade (spec banco-por-cidade §5, Plano 3B).
# Emitidos pelo console (operador) e pelo callback do gov.br (usuário); consumidos
# uma única vez pela cidade. Só ids — nenhum dado pessoal (banco de plataforma).
class CreateCityGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :city_grants, id: :uuid do |t|
      t.uuid     :city_id,     null: false
      t.string   :kind,        null: false
      t.uuid     :subject_id,  null: false
      t.datetime :expires_at,  null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :city_grants, :city_id
    add_foreign_key :city_grants, :cities
    add_check_constraint :city_grants, "kind IN ('operator', 'user')", name: "ck_city_grants_kind"
  end
end
