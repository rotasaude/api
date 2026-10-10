# db/platform_migrate/20261009600001_create_medication_catalog.rb
# Catálogo de medicamentos da plataforma (ADR 0033; spec §3): o CATMAT classe
# 6505 importado pelo maintenance, com o analisador e as marcas das listas da
# Anvisa (antimicrobianos RDC 471, controlados Portaria 344). Um item por
# código CATMAT, estável (a REMUME, os protocolos e as receitas das cidades
# guardam o id), atualizado a cada release e nunca apagado. Dado público, sem
# dado de pessoa. Triggers: db/platform_triggers.sql.
class CreateMedicationCatalog < ActiveRecord::Migration[8.1]
  def text_in(column, values)
    "#{column}::text = ANY (ARRAY[#{values.map { |v| "'#{v}'::text" }.join(', ')}])"
  end

  def up
    create_table :medication_catalog_releases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :source, null: false, default: "catmat_6505"
      t.string :imported_by, null: false, limit: 80
      t.datetime :imported_at, null: false
      t.string :status, null: false, default: "importing"
      t.integer :items_count, null: false, default: 0
      t.integer :hidden_count, null: false, default: 0
      t.integer :added_count, null: false, default: 0
      t.integer :changed_count, null: false, default: 0
      t.integer :removed_count, null: false, default: 0
      t.datetime :activated_at
      t.timestamps
      t.index :status, unique: true, where: "((status)::text = 'active'::text)", name: "idx_medication_catalog_releases_one_active"
      # Uma importação por vez (import_in_progress); a presa há mais de 1 h vira failed antes da próxima.
      t.index :status, unique: true, where: "((status)::text = 'importing'::text)", name: "idx_medication_catalog_releases_one_importing"
      t.check_constraint text_in("status", %w[importing active superseded failed]), name: "ck_medication_catalog_releases_status"
      t.check_constraint "(status::text = 'active'::text) <= (activated_at IS NOT NULL)", name: "ck_medication_catalog_releases_activation"
    end

    create_table :medication_catalog_items, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.integer :catmat_code, null: false
      t.integer :pdm_code
      t.text :source_description, null: false
      t.datetime :source_updated_at
      t.string :active_ingredient, null: false
      t.string :strength
      t.string :dosage_form
      t.string :unit, limit: 20
      t.boolean :antimicrobial, null: false, default: false
      t.boolean :controlled, null: false, default: false
      t.string :controlled_list, limit: 3
      t.string :obm_code
      t.boolean :hidden, null: false, default: false
      t.string :parse_status, null: false
      t.string :review_reason
      t.string :status, null: false, default: "active"
      t.text :search_text, null: false
      t.uuid :first_release_id, null: false
      t.uuid :last_release_id, null: false
      t.timestamps
      t.index :catmat_code, unique: true
      t.index %i[status hidden], name: "idx_medication_catalog_items_prescribable"
      t.index :parse_status
      t.check_constraint text_in("parse_status", %w[ok review]), name: "ck_medication_catalog_items_parse_status"
      t.check_constraint text_in("status", %w[active removed]), name: "ck_medication_catalog_items_status"
      t.check_constraint "parse_status::text = 'ok'::text OR hidden", name: "ck_medication_catalog_items_review_hidden"
      t.check_constraint "parse_status::text = 'review'::text OR strength IS NOT NULL", name: "ck_medication_catalog_items_strength"
      t.check_constraint "controlled = (controlled_list IS NOT NULL)", name: "ck_medication_catalog_items_controlled_list"
      t.check_constraint "obm_code IS NULL", name: "ck_medication_catalog_items_obm_reserved"
      t.check_constraint "catmat_code > 0", name: "ck_medication_catalog_items_catmat_code"
    end
    add_foreign_key :medication_catalog_items, :medication_catalog_releases, column: :first_release_id
    add_foreign_key :medication_catalog_items, :medication_catalog_releases, column: :last_release_id

    create_table :anvisa_list_releases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :imported_by, null: false, limit: 80
      t.datetime :imported_at, null: false
      t.string :status, null: false, default: "importing"
      t.string :source_sha256, null: false, limit: 64
      t.jsonb :sources, null: false, default: {}
      t.integer :antimicrobials_count, null: false, default: 0
      t.integer :controlled_count, null: false, default: 0
      t.datetime :activated_at
      t.timestamps
      t.index :status, unique: true, where: "((status)::text = 'active'::text)", name: "idx_anvisa_list_releases_one_active"
      t.index :status, unique: true, where: "((status)::text = 'importing'::text)", name: "idx_anvisa_list_releases_one_importing"
      t.check_constraint text_in("status", %w[importing active superseded failed]), name: "ck_anvisa_list_releases_status"
    end

    create_table :anvisa_list_substances do |t|
      t.uuid :release_id, null: false
      t.string :kind, null: false
      t.string :substance, null: false
      t.string :substance_key, null: false
      t.string :controlled_list, limit: 3
      t.index %i[release_id kind substance_key], unique: true, name: "idx_anvisa_list_substances_unique"
      t.check_constraint text_in("kind", %w[antimicrobial controlled]), name: "ck_anvisa_list_substances_kind"
      t.check_constraint "(kind::text = 'controlled'::text) = (controlled_list IS NOT NULL)", name: "ck_anvisa_list_substances_list"
      t.check_constraint "controlled_list IS NULL OR controlled_list::text ~ '^[A-F][0-9]?$'::text", name: "ck_anvisa_list_substances_list_code"
    end
    add_foreign_key :anvisa_list_substances, :anvisa_list_releases, column: :release_id

    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
