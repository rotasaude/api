# Módulo 27b (contrato Q12): a carga OBM.
#   - medication_catalog_items.obm_code vira vmp_code: o código do VMP do OBM,
#     preenchido pela coluna CATMAT do arquivo OBM. Sai o CHECK que o mantinha
#     reservado (sempre nulo); entra o formato do código ("@brasil20038375080")
#     e um índice (a busca do estoque vai do VMP ao item).
#   - obm_presentations: as apresentações (AMPP) do OBM. Nunca apagadas
#     (trigger): a que sai do arquivo fica `active = false`. A lista de revisão
#     é a apresentação sem item ativo do catálogo (CATMAT que não casa).
# Nenhum dado de pessoa. Irreversível.
class AddObmPresentations < ActiveRecord::Migration[8.1]
  # O formato do código do OBM, no VMP do item e no AMPP da apresentação.
  OBM_CODE = "'^[@0-9A-Za-z]{1,25}$'".freeze

  def up
    remove_check_constraint :medication_catalog_items, name: "ck_medication_catalog_items_obm_reserved"
    rename_column :medication_catalog_items, :obm_code, :vmp_code
    add_check_constraint :medication_catalog_items, "vmp_code IS NULL OR vmp_code ~ #{OBM_CODE}",
                         name: "ck_medication_catalog_items_vmp_code"
    add_index :medication_catalog_items, :vmp_code, name: "idx_medication_catalog_items_vmp_code"

    create_table :obm_presentations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :ampp_code, null: false
      t.string :vmp_code, null: false
      t.integer :catmat_code
      t.string :anvisa_registration, limit: 13
      t.string :manufacturer_cnpj, limit: 14
      t.string :description, limit: 500, null: false
      t.boolean :active, null: false, default: true
      t.datetime :imported_at, null: false
      t.timestamps
      t.index :ampp_code, unique: true, name: "idx_obm_presentations_ampp"
      t.index :vmp_code, name: "idx_obm_presentations_vmp"
      t.index :catmat_code, name: "idx_obm_presentations_catmat"
      t.check_constraint "ampp_code ~ #{OBM_CODE} AND vmp_code ~ #{OBM_CODE}", name: "ck_obm_presentations_codes"
      t.check_constraint "catmat_code IS NULL OR catmat_code > 0", name: "ck_obm_presentations_catmat"
      t.check_constraint "anvisa_registration IS NULL OR anvisa_registration ~ '^[0-9]{1,13}$'", name: "ck_obm_presentations_anvisa"
      t.check_constraint "manufacturer_cnpj IS NULL OR manufacturer_cnpj ~ '^[0-9]{14}$'", name: "ck_obm_presentations_cnpj"
      t.check_constraint "char_length(description) BETWEEN 1 AND 500", name: "ck_obm_presentations_description"
    end
    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
