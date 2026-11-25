require "rails_helper"

# Módulo 27b (Task 3): dados BNAFAR do lote (Q7, Q15, Q16), CNES dos locais
# centrais, CATMAT do produto vetorial e ambiente da credencial (Q9). O banco
# segura o formato; o trigger stock_lots_bnafar_guard congela o resto do lote.
RSpec.describe "Esquema dos dados BNAFAR do estoque (módulo 27b)", type: :model do
  before { pharmacy_city! }
  let(:keeper) { pharmacy_admin! }

  def lot!(**over)
    StockLot.create!({ catalog_item_id: losartana.id, catmat_code: 268_856, lot_number: "B#{SecureRandom.hex(3).upcase}",
                       expires_on: Date.current + 200, dispensing_unit: "comprimido", created_by_user: keeper }.merge(over))
  end

  # Escrita crua (update_columns, SQL) que o banco recusa, sem abortar a
  # transação do exemplo.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  describe "stock_lots" do
    it "CNPJ 12ABC34501DE35 passa e 1234 cai" do
      expect(lot!(manufacturer_cnpj: "12ABC34501DE35").manufacturer_cnpj).to eq("12ABC34501DE35")
      refused(/ck_stock_lots_manufacturer_cnpj/) { lot!(manufacturer_cnpj: "1234") }
    end

    it "ANVISA de 11 e de 13 dígitos passa; 12 dígitos cai" do
      expect(lot!(anvisa_registration: "12345678901").anvisa_registration).to eq("12345678901")
      expect(lot!(anvisa_registration: "1234567890123").anvisa_registration).to eq("1234567890123")
      refused(/ck_stock_lots_anvisa/) { lot!(anvisa_registration: "123456789012") }
    end

    it "preço, versão e ampp_code têm limites" do
      refused(/ck_stock_lots_unit_price/) { lot!(unit_price_cents: 0) }
      refused(/ck_stock_lots_bnafar_version/) { lot!(bnafar_version: -1) }
      expect(lot!(unit_price_cents: 1250, ampp_code: "AMPP-1", health_program: "PNI", ium: %w[A B]).unit_price_cents).to eq(1250)
    end

    it "ampp_code num lote vetorial cai" do
      product = vector_product!
      refused(/ck_stock_lots_ampp_vector/) do
        StockLot.create!(item_kind: "vector_control", vector_product_id: product.id, lot_number: "V1", expires_on: Date.current + 100,
                         dispensing_unit: "g", created_by_user: keeper, ampp_code: "AMPP-1")
      end
    end

    it "internacional com CNPJ cai; sem fabricante cai; com nome passa" do
      refused(/ck_stock_lots_international/) { lot!(manufacturer_international: true, manufacturer_cnpj: "12ABC34501DE35", manufacturer: "Acme") }
      refused(/ck_stock_lots_international/) { lot!(manufacturer_international: true) }
      expect(lot!(manufacturer_international: true, manufacturer: "Acme Ltd").manufacturer_international).to be(true)
    end

    it "lote antigo nasce com bnafar_version 0 e o internacional falso" do
      row = lot!
      expect([ row.reload.bnafar_version, row.manufacturer_international ]).to eq([ 0, false ])
    end

    it "preencher o CNPJ nulo com versão + 1 passa" do
      row = lot!
      row.update_columns(manufacturer_cnpj: "12ABC34501DE35", bnafar_version: 1)
      expect(row.reload.manufacturer_cnpj).to eq("12ABC34501DE35")
    end

    it "preencher ium e anvisa nulos com versão + 1 passa" do
      row = lot!
      row.update_columns(ium: %w[X1 X2], anvisa_registration: "12345678901", health_program: "PNI", ampp_code: "AMPP-9", bnafar_version: 1)
      expect(row.reload.ium).to eq(%w[X1 X2])
    end

    it "trocar um CNPJ preenchido cai no trigger" do
      row = lot!(manufacturer_cnpj: "12ABC34501DE35")
      refused(/stock_lots/) { row.update_columns(manufacturer_cnpj: "12ABC34501DE36", bnafar_version: 1) }
    end

    it "trocar o preço preenchido passa" do
      row = lot!(unit_price_cents: 100)
      row.update_columns(unit_price_cents: 250, bnafar_version: 1)
      expect(row.reload.unit_price_cents).to eq(250)
    end

    it "sem subir a versão cai no trigger" do
      row = lot!
      refused(/stock_lots/) { row.update_columns(manufacturer_cnpj: "12ABC34501DE35") }
      refused(/stock_lots/) { row.update_columns(manufacturer_cnpj: "12ABC34501DE35", bnafar_version: 2) }
    end

    it "mudar expires_on cai no trigger, mesmo subindo a versão" do
      row = lot!
      refused(/stock_lots/) { row.update_columns(expires_on: Date.current + 300, bnafar_version: 1) }
    end

    it "lote antigo sem fabricante recebe o internacional com nome e versão + 1" do
      row = lot!
      row.update_columns(manufacturer_international: true, manufacturer: "Acme Ltd", bnafar_version: 1)
      expect([ row.reload.manufacturer, row.manufacturer_international ]).to eq([ "Acme Ltd", true ])
    end

    it "o fabricante já preenchido não troca" do
      row = lot!(manufacturer: "Antiga")
      refused(/stock_lots/) { row.update_columns(manufacturer: "Outra", bnafar_version: 1) }
    end

    it "DELETE cai no trigger" do
      row = lot!
      refused(/stock_lots/) { row.delete }
    end
  end

  describe "stock_locations" do
    it "CNES de 7 dígitos nos centrais passa; num unit cai; malformado cai" do
      central = StockLocation.create!(kind: "central", name: "Central BNAFAR", updated_by_user: keeper, cnes: "1234567")
      expect(central.reload.cnes).to eq("1234567")
      refused(/ck_stock_locations_cnes_kind/) { unit_location!.update_columns(cnes: "1234567") }
      refused(/ck_stock_locations_cnes/) { central.update_columns(cnes: "12345") }
    end

    it "bnafar_cnes do unit é o da unidade; o do central é o próprio" do
      location = unit_location!
      location.health_unit.update!(cnes: "7654321")
      expect(location.reload.bnafar_cnes).to eq("7654321")
      central = StockLocation.create!(kind: "central", name: "Central BNAFAR", updated_by_user: keeper, cnes: "1234567")
      expect(central.bnafar_cnes).to eq("1234567")
    end
  end

  describe "vector_products" do
    it "catmat_code positivo" do
      expect(vector_product!.tap { |p| p.update!(catmat_code: 123) }.catmat_code).to eq(123)
      refused(/ck_vector_products_catmat/) { vector_product!.update_columns(catmat_code: 0) }
    end
  end

  describe "integration_credentials" do
    let(:secret) { { "username" => "u", "password" => "p" } }

    def credential(kind, environment)
      IntegrationCredential.new(kind: kind, environment: environment, secret: secret, set_by_user: keeper, set_at: Time.current)
    end

    it "duas bnafar (uma por ambiente) passam" do
      credential("bnafar", "homologation").save!
      credential("bnafar", "production").save!
      expect(IntegrationCredential.where(kind: "bnafar").pluck(:environment)).to match_array(%w[homologation production])
    end

    it "rnds em homologation cai no CHECK" do
      refused(/ck_integration_credentials_environment_kind/) { credential("rnds", "homologation").save!(validate: false) }
    end

    it "duas bnafar production caem no único" do
      credential("bnafar", "production").save!
      refused(/idx_integration_credentials_kind_environment|unique/i) { credential("bnafar", "production").save!(validate: false) }
      expect(credential("bnafar", "production")).not_to be_valid
    end

    it "ambiente fora da lista cai" do
      refused(/ck_integration_credentials_environment/) { credential("bnafar", "staging").save!(validate: false) }
    end

    it "as credenciais antigas ficam production" do
      credential("ledi", "production").save!
      expect(IntegrationCredential.find_by!(kind: "ledi").environment).to eq("production")
      expect(IntegrationCredential.new.environment).to eq("production")
    end
  end
end
