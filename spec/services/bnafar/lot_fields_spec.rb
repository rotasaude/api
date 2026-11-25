require "rails_helper"

# Módulo 27b, Task 5 (Q7, Q15, Q17, Q21): os campos BNAFAR do lote lidos do
# corpo (entrada e complemento), sem banco do lote.
RSpec.describe Bnafar::LotFields, type: :model do
  let(:med) { Stock::Domain::MEDICATION }
  let(:vector) { Stock::Domain::VECTOR_CONTROL }
  let(:vaccine) { Stock::Domain::IMMUNOBIOLOGICAL }
  let(:cnpj) { Cnpj.with_check_digits("11222333000181"[0, 12]) }

  def presentation!(ampp: "@brasil20038375080", vmp: "@brasil1000", anvisa: "1234567890123", active: true)
    ObmPresentation.create!(ampp_code: ampp, vmp_code: vmp, anvisa_registration: anvisa, description: "Losartana 50 mg", active: active,
                            imported_at: Time.current)
  end

  def complete(**over)
    { "unit_price_cents" => 1250, "manufacturer_cnpj" => cnpj, "anvisa_registration" => "1234567890123", "health_program" => "AFB" }
      .merge(over.transform_keys(&:to_s))
  end

  def parse(raw, domain: med, required: false, vmp_code: nil, prefix: "items[0]")
    described_class.parse(raw, prefix: prefix, stock_domain: domain, required: required, vmp_code: vmp_code)
  end

  it "campos válidos voltam normalizados e sem problema" do
    fields, problems = parse(complete("ium" => [ "ABC123" ]))
    expect(problems).to eq([])
    expect(fields).to eq(unit_price_cents: 1250, manufacturer_cnpj: cnpj, anvisa_registration: "1234567890123", health_program: "AFB",
                         ium: [ "ABC123" ])
  end

  it "CNPJ inválido é invalid_cnpj e com máscara é normalizado" do
    expect(parse(complete("manufacturer_cnpj" => "11.222.333/0001-80")).last).to eq([ { path: "items[0].manufacturer_cnpj", error: "invalid_cnpj" } ])
    expect(parse(complete("manufacturer_cnpj" => Cnpj.display(cnpj))).first).to include(manufacturer_cnpj: cnpj)
  end

  it "preço fora de 1..2_000_000_000 e ANVISA fora do formato são invalid_request" do
    problems = parse(complete("unit_price_cents" => 0, "anvisa_registration" => "123")).last
    expect(problems).to contain_exactly({ path: "items[0].unit_price_cents", error: "invalid_request" },
                                        { path: "items[0].anvisa_registration", error: "invalid_request" })
  end

  it "`INSULDEP I` aceita; `XYZ` → program_unknown" do
    expect(parse(complete("health_program" => "INSULDEP I")).last).to eq([])
    expect(parse(complete("health_program" => "XYZ")).last).to eq([ { path: "items[0].health_program", error: "program_unknown" } ])
  end

  describe "AMPP" do
    it "inexistente (ou inativo) → ampp_unknown" do
      expect(parse(complete("ampp_code" => "@nada"), vmp_code: "@brasil1000").last).to eq([ { path: "items[0].ampp_code", error: "ampp_unknown" } ])
      presentation!(active: false)
      expect(parse(complete("ampp_code" => "@brasil20038375080"), vmp_code: "@brasil1000").last.map { |p| p[:error] }).to eq([ "ampp_unknown" ])
    end

    it "de outro VMP → ampp_not_in_vmp" do
      presentation!(vmp: "@brasil2000")
      expect(parse(complete("ampp_code" => "@brasil20038375080"), vmp_code: "@brasil1000").last)
        .to eq([ { path: "items[0].ampp_code", error: "ampp_not_in_vmp" } ])
    end

    it "ANVISA diferente da apresentação → anvisa_mismatch" do
      presentation!
      expect(parse(complete("ampp_code" => "@brasil20038375080", "anvisa_registration" => "9999999999999"), vmp_code: "@brasil1000").last)
        .to eq([ { path: "items[0].anvisa_registration", error: "anvisa_mismatch" } ])
    end

    it "apresentação do mesmo VMP e mesma ANVISA passa" do
      presentation!
      fields, problems = parse(complete("ampp_code" => "@brasil20038375080"), vmp_code: "@brasil1000")
      expect([ problems, fields[:ampp_code] ]).to eq([ [], "@brasil20038375080" ])
    end

    it "item sem VMP não exige AMPP (Q15), mesmo com required" do
      expect(parse(complete, required: true, vmp_code: nil).last).to eq([])
      expect(parse(complete, required: true, vmp_code: "@brasil1000").last).to eq([ { path: "items[0].ampp_code", error: "required" } ])
    end

    it "produto vetorial recusa ampp_code" do
      expect(parse(complete("ampp_code" => "@x"), domain: vector).last).to eq([ { path: "items[0].ampp_code", error: "invalid_request" } ])
    end
  end

  describe "fabricante internacional (Q15)" do
    it "com nome e sem CNPJ passa" do
      fields, problems = parse(complete("manufacturer_cnpj" => nil, "manufacturer_international" => true, "manufacturer" => "Pfizer Inc."),
                               required: true, vmp_code: nil)
      expect(problems).to eq([])
      expect(fields).to include(manufacturer_international: true, manufacturer: "Pfizer Inc.")
      expect(fields).not_to have_key(:manufacturer_cnpj)
    end

    it "sem nome → required em items[0].manufacturer" do
      problems = parse(complete("manufacturer_cnpj" => nil, "manufacturer_international" => true)).last
      expect(problems).to eq([ { path: "items[0].manufacturer", error: "required" } ])
    end

    it "com CNPJ junto é invalid_request" do
      problems = parse(complete("manufacturer_international" => true, "manufacturer" => "X")).last
      expect(problems).to eq([ { path: "items[0].manufacturer_cnpj", error: "invalid_request" } ])
    end
  end

  describe "required: true" do
    it "todos os ausentes de uma vez, na ordem do contrato" do
      problems = parse({}, required: true).last
      expect(problems).to eq(%w[unit_price_cents manufacturer_cnpj anvisa_registration health_program].map { |f| { path: "items[0].#{f}", error: "required" } })
    end

    it "com required: false, tudo é opcional" do
      expect(parse({}, required: false)).to eq([ {}, [] ])
    end
  end

  describe "vacina (Q21)" do
    it "não exige nem aceita manufacturer_cnpj (o CNPJ vem do YAML)" do
      expect(parse(complete.except("manufacturer_cnpj"), domain: vaccine, required: true).last).to eq([])
      expect(parse(complete, domain: vaccine).last).to eq([ { path: "items[0].manufacturer_cnpj", error: "invalid_request" } ])
      expect(parse(complete.except("manufacturer_cnpj").merge("manufacturer_international" => true), domain: vaccine).last)
        .to eq([ { path: "items[0].manufacturer_international", error: "invalid_request" } ])
    end

    it "sem preço, ANVISA e programa, com required, recusa só esses" do
      problems = parse({}, domain: vaccine, required: true).last
      expect(problems.map { |p| p[:path] }).to eq(%w[items[0].unit_price_cents items[0].anvisa_registration items[0].health_program])
    end
  end

  describe ".missing" do
    let(:item) { catalog_item(267_778) }
    let(:admin) { pharmacy_admin! }

    before { pharmacy_city! }

    def lot!(**attrs)
      StockLot.create!({ catalog_item_id: item.id, catmat_code: item.catmat_code, lot_number: "M#{SecureRandom.hex(3)}",
                         expires_on: Time.zone.today + 90, dispensing_unit: "comprimido", created_by_user: admin }.merge(attrs))
    end

    it "lote anterior ao 27b: tudo que falta (AMPP só com VMP)" do
      expect(described_class.missing(described_class_lot = lot!, vmp_code: nil))
        .to eq(%w[unit_price_cents manufacturer_cnpj anvisa_registration health_program])
      expect(described_class.missing(described_class_lot, vmp_code: "@brasil1")).to end_with("ampp_code")
    end

    it "lote completo não falta nada; internacional conta como fabricante" do
      expect(described_class.missing(lot!(unit_price_cents: 1, manufacturer_cnpj: cnpj, anvisa_registration: "12345678901", health_program: "AFB"),
                                     vmp_code: nil)).to eq([])
      expect(described_class.missing(lot!(unit_price_cents: 1, manufacturer: "Pfizer", manufacturer_international: true,
                                          anvisa_registration: "12345678901", health_program: "AFB"), vmp_code: nil)).to eq([])
    end

    it "vacina: o CNPJ vem do YAML, e sem CNPJ lá `manufacturer_cnpj` falta (Q21)" do
      lot = lot!(catalog_item_id: nil, catmat_code: nil, item_kind: "immunobiological", immunobiological_code: "42", manufacturer_key: "serum",
                 dispensing_unit: "dose", unit_price_cents: 1, anvisa_registration: "12345678901", health_program: "IMUN")
      expect(described_class.missing(lot)).to eq(%w[manufacturer_cnpj])
    end
  end

  describe ".diff" do
    let(:item) { catalog_item(267_778) }
    let(:lot) do
      pharmacy_city!
      StockLot.create!(catalog_item_id: item.id, catmat_code: item.catmat_code, lot_number: "D1", expires_on: Time.zone.today + 90,
                       dispensing_unit: "comprimido", created_by_user: pharmacy_admin!, manufacturer_cnpj: cnpj, unit_price_cents: 100)
    end

    it "preenche o nulo, troca o preço e acusa o preenchido diferente" do
      changes, conflicts = described_class.diff(lot, unit_price_cents: 200, anvisa_registration: "12345678901", manufacturer_cnpj: cnpj)
      expect([ changes, conflicts ]).to eq([ { unit_price_cents: 200, anvisa_registration: "12345678901" }, [] ])
      expect(described_class.diff(lot, health_program: "AFB", manufacturer_cnpj: "11444777000161").last).to eq([ :manufacturer_cnpj ])
      expect(described_class.diff(lot, unit_price_cents: 100).first).to eq({})
    end
  end
end
