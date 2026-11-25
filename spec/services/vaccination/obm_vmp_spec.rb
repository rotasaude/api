require "rails_helper"

# Módulo 27b, Task 6 (contrato Q13, Q21): `obm_vmp` por produto e `cnpj` por
# fabricante no YAML dos imunobiológicos (nulos até o gate de go-live).
RSpec.describe "Imunobiológicos — OBM e CNPJ do fabricante", type: :service do
  let(:products) { Vaccination::Immunobiologicals.all }

  it "todo produto tem obm_vmp e todo fabricante cnpj (nulos por ora); under_review? não muda" do
    expect(products).to all(respond_to(:obm_vmp))
    expect(products.map(&:obm_vmp)).to all(be_nil)
    expect(products.flat_map(&:manufacturers)).to all(respond_to(:cnpj))
    expect(products.flat_map(&:manufacturers).map(&:cnpj)).to all(be_nil)
    expect(Vaccination::Immunobiologicals::Manufacturer.members).not_to include(:under_review)
    expect(products.flat_map(&:manufacturers).map(&:review)).to all(be(true))
    expect(products.map(&:review)).to all(be(true))
    expect(Vaccination::Catalog.under_review?).to be(true)
  end

  it "manufacturer_by_cnpj acha pela CNPJ normalizada" do
    cnpj = "11222333000181"
    product = Vaccination::Immunobiologicals.find("15")
    manufacturer = product.manufacturer("fiocruz")
    stub = manufacturer.with(cnpj: cnpj)
    patched = product.with(manufacturers: product.manufacturers.map { |m| m.key == "fiocruz" ? stub : m })

    expect(Vaccination::Immunobiologicals.manufacturer_by_cnpj(patched, "11.222.333/0001-81")).to eq(stub)
    expect(Vaccination::Immunobiologicals.manufacturer_by_cnpj(patched, cnpj)).to eq(stub)
    expect(Vaccination::Immunobiologicals.manufacturer_by_cnpj(patched, "11222333000182")).to be_nil
    expect(Vaccination::Immunobiologicals.manufacturer_by_cnpj(patched, nil)).to be_nil
    expect(Vaccination::Immunobiologicals.manufacturer_by_cnpj(product, cnpj)).to be_nil
  end
end
