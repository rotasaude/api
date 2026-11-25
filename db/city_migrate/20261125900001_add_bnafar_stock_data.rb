# Módulo 27b (BNAFAR; plano, Task 3; Q7, Q9, Q15, Q16): os dados do envio no
# estoque e a credencial por ambiente.
#   - stock_lots: preço unitário, CNPJ do fabricante (Q7: 12 alfanuméricos e 2
#     dígitos), fabricante internacional (Q15: sem CNPJ e com o nome), registro
#     ANVISA (11 ou 13 dígitos), programa de saúde, IUM, código AMPP (nunca no
#     lote vetorial) e bnafar_version (Q16: o lote antigo começa em 0). O
#     trigger stock_lots_bnafar_guard troca o só-acréscimo do lote: o UPDATE
#     sobe a versão em 1 e só completa os dados BNAFAR (de NULL a valor), mais
#     a troca do preço; o resto do lote nunca muda; o lote nunca some;
#   - stock_locations: CNES, só nos dois centrais;
#   - vector_products: código CATMAT;
#   - integration_credentials: ambiente (homologation | production); só a
#     bnafar tem homologação; único (tipo, ambiente); o tipo aceita bnafar.
# Triggers em db/city_triggers.sql (o dump não representa trigger).
# Irreversível.
class AddBnafarStockData < ActiveRecord::Migration[8.1]
  KINDS = %w[ledi cadsus rnds bnafar].freeze
  ENVIRONMENTS = %w[homologation production].freeze

  def up
    change_lots
    change_locations
    change_products
    change_credentials

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def change_lots
    add_column :stock_lots, :unit_price_cents, :integer
    add_column :stock_lots, :manufacturer_cnpj, :string, limit: 14
    add_column :stock_lots, :manufacturer_international, :boolean, null: false, default: false
    add_column :stock_lots, :anvisa_registration, :string, limit: 13
    add_column :stock_lots, :health_program, :string, limit: 10
    add_column :stock_lots, :ium, :text, array: true
    add_column :stock_lots, :ampp_code, :string, limit: 25
    add_column :stock_lots, :bnafar_version, :integer, null: false, default: 0
    add_check_constraint :stock_lots, "unit_price_cents IS NULL OR unit_price_cents > 0", name: "ck_stock_lots_unit_price"
    add_check_constraint :stock_lots, "manufacturer_cnpj IS NULL OR manufacturer_cnpj::text ~ '^[0-9A-Z]{12}[0-9]{2}$'::text",
                         name: "ck_stock_lots_manufacturer_cnpj"
    add_check_constraint :stock_lots, "NOT manufacturer_international OR (manufacturer_cnpj IS NULL AND manufacturer IS NOT NULL)",
                         name: "ck_stock_lots_international"
    add_check_constraint :stock_lots, "anvisa_registration IS NULL OR anvisa_registration::text ~ '^([0-9]{11}|[0-9]{13})$'::text",
                         name: "ck_stock_lots_anvisa"
    add_check_constraint :stock_lots, "ampp_code IS NULL OR item_kind::text <> 'vector_control'::text", name: "ck_stock_lots_ampp_vector"
    add_check_constraint :stock_lots, "bnafar_version >= 0", name: "ck_stock_lots_bnafar_version"
  end

  def change_locations
    add_column :stock_locations, :cnes, :string, limit: 7
    add_check_constraint :stock_locations, "cnes IS NULL OR cnes::text ~ '^[0-9]{7}$'::text", name: "ck_stock_locations_cnes"
    add_check_constraint :stock_locations, "cnes IS NULL OR kind::text = ANY (ARRAY['central'::text, 'cold_chain_central'::text])",
                         name: "ck_stock_locations_cnes_kind"
  end

  def change_products
    add_column :vector_products, :catmat_code, :integer
    add_check_constraint :vector_products, "catmat_code IS NULL OR catmat_code > 0", name: "ck_vector_products_catmat"
  end

  def change_credentials
    add_column :integration_credentials, :environment, :string, null: false, default: "production"
    remove_index :integration_credentials, name: "index_integration_credentials_on_kind"
    add_index :integration_credentials, %i[kind environment], unique: true, name: "idx_integration_credentials_kind_environment"
    replace_check :integration_credentials, "ck_integration_credentials_kind", "kind::text = ANY (ARRAY[#{quoted(KINDS)}])"
    add_check_constraint :integration_credentials, "environment::text = ANY (ARRAY[#{quoted(ENVIRONMENTS)}])",
                         name: "ck_integration_credentials_environment"
    add_check_constraint :integration_credentials, "kind::text = 'bnafar'::text OR environment::text = 'production'::text",
                         name: "ck_integration_credentials_environment_kind"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
