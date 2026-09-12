# Catálogo de cidades. `slug` é o subdomínio e o nome do shard.
class CreateCities < ActiveRecord::Migration[8.1]
  def change
    create_table :cities, id: :uuid do |t|
      t.string :slug,           null: false
      t.string :name,           null: false
      t.string :uf,             limit: 2
      t.string :status,         null: false, default: "provisioning"
      t.text   :database_url,   null: false
      t.text   :encryption_key, null: false
      t.string :schema_version
      t.timestamps
    end

    add_index :cities, :slug, unique: true

    add_check_constraint :cities,
      "status IN ('provisioning','active','suspended','archived')",
      name: "ck_cities_status"

    add_check_constraint :cities,
      "slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' AND length(slug) BETWEEN 2 AND 63",
      name: "ck_cities_slug_is_dns_label"
  end
end
