# Municípios — stub mínimo. Referenciado por conversations, dashboard_metrics,
# protocol_definitions. Model próprio fica em ADR futuro.
class CreateMunicipalities < ActiveRecord::Migration[8.0]
  def change
    create_table :municipalities, id: :uuid do |t|
      t.string :name,    null: false
      t.string :slug,    null: false
      t.string :ibge_code
      t.string :uf, limit: 2
      t.jsonb  :settings, null: false, default: {}
      t.timestamps
    end

    add_index :municipalities, :slug, unique: true
    add_index :municipalities, :ibge_code, unique: true, where: "ibge_code IS NOT NULL"
  end
end
