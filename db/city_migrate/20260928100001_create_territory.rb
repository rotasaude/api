# Território (ADR 0023; spec 2026-09-28-module-11-territory §3): bairros da
# cidade, cobertura (bairro → unidades), endereço da unidade, bairro declarado
# pelo cidadão e bairro COPIADO na triagem, imutável depois — trigger em
# db/city_triggers.sql, a mesma fonte que load_city_schema executa depois de
# carregar o dump. Só expansão: nada existente muda de forma.
class CreateTerritory < ActiveRecord::Migration[8.1]
  def up
    create_table :neighborhoods, id: :uuid do |t|
      t.string :name, limit: 120, null: false
      t.boolean :active, null: false, default: true
      t.string :source, null: false
      # Chave estável da semente (desvio 13): casa item do YAML com a linha
      # mesmo depois de renomeada; nula em bairro manual.
      t.string :seed_key
      t.timestamps
    end
    add_index :neighborhoods, "lower((name)::text)", unique: true, name: "idx_neighborhoods_name_ci"
    add_index :neighborhoods, :seed_key, unique: true, where: "(seed_key IS NOT NULL)", name: "idx_neighborhoods_seed_key"
    add_check_constraint :neighborhoods, "length(btrim(name::text)) > 0 AND name::text = btrim(name::text)",
                         name: "ck_neighborhoods_name"
    add_check_constraint :neighborhoods, "source::text = ANY (ARRAY['seed'::text, 'manual'::text])",
                         name: "ck_neighborhoods_source"

    create_table :neighborhood_coverages, id: :uuid do |t|
      t.references :neighborhood, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :created_at, null: false
    end
    add_index :neighborhood_coverages, %i[neighborhood_id health_unit_id], unique: true,
              name: "idx_neighborhood_coverages_pair"

    add_column :health_units, :address_street, :string, limit: 160
    add_column :health_units, :address_number, :string, limit: 20
    add_column :health_units, :address_complement, :string, limit: 80
    add_column :health_units, :address_zip, :string, limit: 8
    add_check_constraint :health_units, "address_zip IS NULL OR address_zip::text ~ '^[0-9]{8}$'::text",
                         name: "ck_health_units_address_zip"
    add_reference :health_units, :neighborhood, type: :uuid, foreign_key: true, index: true

    add_reference :citizens, :neighborhood, type: :uuid, foreign_key: true, index: true

    add_reference :triages, :neighborhood, type: :uuid, foreign_key: true, index: false
    add_index :triages, %i[neighborhood_id created_at], name: "idx_triages_neighborhood_created"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS triages_neighborhood_immutable ON triages"
    execute "DROP FUNCTION IF EXISTS rota_triage_neighborhood_guard()"
    remove_reference :triages, :neighborhood, foreign_key: true, index: false
    remove_reference :citizens, :neighborhood, foreign_key: true, index: true
    remove_reference :health_units, :neighborhood, foreign_key: true, index: true
    remove_check_constraint :health_units, name: "ck_health_units_address_zip"
    remove_column :health_units, :address_zip
    remove_column :health_units, :address_complement
    remove_column :health_units, :address_number
    remove_column :health_units, :address_street
    drop_table :neighborhood_coverages
    drop_table :neighborhoods
  end
end
