require "rails_helper"

# Módulo 27b, Task 14 (Valor 11; Q13, Q15, Q21, Q26; R7, R8, R9, R24): a
# conferência linha a linha da planilha. Um teste por código. O YAML dos
# imunobiológicos tem `cnpj: null` até o gate de go-live (R8): a vacina usa o
# produto "15" com o CNPJ do fabricante `fiocruz` preenchido no stub.
RSpec.describe OpeningImports::Validator, type: :service do
  let(:med) { Stock::Domain::MEDICATION }
  let(:vaccine) { Stock::Domain::IMMUNOBIOLOGICAL }
  let(:vector) { Stock::Domain::VECTOR_CONTROL }
  let(:all_domains) { [ med, vaccine, vector ] }

  before { pharmacy_city! }

  let(:unit) { create_unit("UBS Centro", cnes: "7654321") }
  let!(:central) { central_location!.tap { |location| location.update!(cnes: "2384299") } }
  let!(:farmacia) { unit_location!(unit) }
  let!(:room) { vaccine_room!(unit).stock_location }
  let!(:cold) { cold_chain_central!.tap { |location| location.update!(cnes: "3333333") } }
  let!(:base) { vector_location!(create_unit("UVZ Norte", kind: "environmental_surveillance", cnes: "4444444")) }
  let(:product) { Vaccination::Immunobiologicals.find("15") }
  let(:fiocruz_cnpj) { bnafar_cnpj }

  before do
    patched = product.with(manufacturers: product.manufacturers.map { |m| m.key == "fiocruz" ? m.with(cnpj: fiocruz_cnpj) : m })
    allow(Vaccination::Immunobiologicals).to receive(:find).and_call_original
    allow(Vaccination::Immunobiologicals).to receive(:find).with("15").and_return(patched)
  end

  # Lote próprio por linha (`LOS-<linha>`): o mesmo lote outra vez é duplicate_line.
  def row(line: 2, **over)
    { line: line, cnes: "2384299", tipo_produto: "medicamento", codigo_produto: losartana.catmat_code.to_s, ampp: nil, lote: "LOS-#{line}",
      validade: (Time.zone.today + 200).iso8601, quantidade: "100", valor_unitario: "1.234,56", cnpj_fabricante: bnafar_cnpj,
      registro_anvisa: "1234567890123", programa: "HIPERTEN" }.merge(over)
  end

  def vaccine_row(**over) = row(cnes: "3333333", tipo_produto: "vacina", codigo_produto: "15", lote: "VAC-1", quantidade: "3",
                                valor_unitario: "12,00", cnpj_fabricante: fiocruz_cnpj, programa: "IMUN", **over)

  def validate(*rows, usable: all_domains, required: [])
    described_class.call(rows: rows, today: Time.zone.today, usable_domains: usable, required_domains: required)
  end

  def codes_of(*rows, **opts) = validate(*rows, **opts).map(&:error_codes)

  it "linha completa de medicamento é válida, com local, item, quantidade e preço" do
    result = validate(row).sole
    expect(result).to have_attributes(status: "valid", error_codes: [], stock_location_id: central.id, item_kind: med,
                                      catalog_item_id: losartana.id, quantity: BigDecimal("100"), value_cents: 100 * 123_456,
                                      send_fields_missing: false)
  end

  it "vacina com 3 frascos de 10 doses → 30 doses e a manufacturer_key pela CNPJ (Q21)" do
    result = validate(vaccine_row).sole
    expect(result).to have_attributes(status: "valid", stock_location_id: cold.id, item_kind: vaccine, immunobiological_code: "15",
                                      manufacturer_key: "fiocruz", quantity: BigDecimal("30"), value_cents: 3 * 1200)
  end

  it "o mesmo CNES na farmácia e na sala de vacina resolve pelo tipo do produto" do
    medication, vaccination = validate(row(cnes: "7654321"), vaccine_row(line: 3, cnes: "7654321"))
    expect([ medication.stock_location_id, vaccination.stock_location_id ]).to eq([ farmacia.id, room.id ])
  end

  it "vetorial pelo code do produto, sem embalagem" do
    supply = vector_product!(code: "PYR1")
    result = validate(row(cnes: "4444444", tipo_produto: "vetorial", codigo_produto: "pyr1", quantidade: "500")).sole
    expect(result).to have_attributes(status: "valid", stock_location_id: base.id, item_kind: vector, vector_product_id: supply.id,
                                      quantity: BigDecimal("500"))
  end

  it "cnes_unknown: CNES sem local ativo ou malformado" do
    expect(codes_of(row(cnes: "9999999"), row(line: 3, cnes: "abc"), row(line: 4, cnes: nil))).to all(include("cnes_unknown"))
  end

  it "product_unknown: CATMAT, código do YAML ou code vetorial fora do catálogo" do
    found = codes_of(row(codigo_produto: "999999999"), vaccine_row(line: 3, codigo_produto: "999"),
                     row(line: 4, cnes: "4444444", tipo_produto: "vetorial", codigo_produto: "NADA"))
    expect(found).to all(eq([ "product_unknown" ]))
  end

  it "invalid_product_type" do
    expect(codes_of(row(tipo_produto: "remedio"))).to eq([ [ "invalid_product_type" ] ])
  end

  it "item_not_allowed_here: o CNES existe, mas não tem local do domínio do produto" do
    expect(codes_of(vaccine_row(cnes: "2384299"))).to eq([ [ "item_not_allowed_here" ] ])
  end

  it "domain_disabled: o domínio do local não está utilizável (R24)" do
    expect(codes_of(row, usable: [ vaccine ])).to eq([ [ "domain_disabled" ] ])
  end

  it "invalid_lot_number" do
    expect(codes_of(row(lote: "LOTE 1"), row(line: 3, lote: nil))).to all(eq([ "invalid_lot_number" ]))
  end

  it "invalid_date e expired_lot" do
    expect(codes_of(row(validade: "30/06/2027"), row(line: 3, validade: "2027-02-30"))).to all(eq([ "invalid_date" ]))
    expect(codes_of(row(validade: (Time.zone.today - 1).iso8601))).to eq([ [ "expired_lot" ] ])
  end

  it "invalid_quantity: zero, decimal, texto, acima do teto, frascos acima do teto" do
    found = codes_of(row(quantidade: "0"), row(line: 3, quantidade: "1,5"), row(line: 4, quantidade: "abc"),
                     row(line: 5, quantidade: "100000"), vaccine_row(line: 6, quantidade: "10001"))
    expect(found).to all(eq([ "invalid_quantity" ]))
  end

  it "invalid_price: moeda, três casas, zero" do
    found = codes_of(row(valor_unitario: "R$ 1,00"), row(line: 3, valor_unitario: "1,234"), row(line: 4, valor_unitario: "0,00"),
                     row(line: 5, valor_unitario: "1.2,00"))
    expect(found).to all(eq([ "invalid_price" ]))
  end

  it "valor_unitario aceita vírgula, uma casa e ponto de milhar" do
    found = validate(row(valor_unitario: "1.234.567,8"), row(line: 3, valor_unitario: "7"))
    expect(found.map(&:value_cents)).to eq([ 100 * 123_456_780, 100 * 700 ])
  end

  it "invalid_cnpj" do
    expect(codes_of(row(cnpj_fabricante: "11222333000182"))).to eq([ [ "invalid_cnpj" ] ])
  end

  it "invalid_anvisa" do
    expect(codes_of(row(registro_anvisa: "123"))).to eq([ [ "invalid_anvisa" ] ])
  end

  it "ampp_unknown e anvisa_mismatch pela apresentação do OBM" do
    ObmPresentation.create!(ampp_code: "@brasil20038375080", vmp_code: "@brasil1000", anvisa_registration: "1234567890123",
                            description: "Losartana 50 mg", imported_at: Time.current)
    expect(codes_of(row(ampp: "@nada"))).to eq([ [ "ampp_unknown" ] ])
    expect(codes_of(row(ampp: "@brasil20038375080", registro_anvisa: "9876543210123"))).to eq([ [ "anvisa_mismatch" ] ])
    expect(codes_of(row(ampp: "@brasil20038375080"))).to eq([ [] ])
  end

  it "ampp_not_in_vmp: o AMPP existe no catálogo OBM, mas é de outro VMP (Q36)" do
    ObmPresentation.create!(ampp_code: "@brasil20038375080", vmp_code: "@brasil1000", anvisa_registration: "1234567890123",
                            description: "Losartana 50 mg", imported_at: Time.current)
    losartana.update_columns(vmp_code: "@brasil9999") # rubocop:disable Rails/SkipsModelValidations
    expect(codes_of(row(ampp: "@brasil20038375080"))).to eq([ [ "ampp_not_in_vmp" ] ])
    expect(codes_of(row(ampp: "@nada"))).to eq([ [ "ampp_unknown" ] ])
  end

  describe "lot_mismatch (Q37, regra da Q7)" do
    let(:later) { (Time.zone.today + 300).iso8601 }

    it "(a) o mesmo lote em linhas de locais diferentes com validade, CNPJ ou ANVISA divergentes → todas as linhas do conflito" do
      expect(codes_of(row(lote: "X-1"), row(line: 3, cnes: "7654321", lote: "X-1", validade: later), row(line: 4, lote: "X-2")))
        .to eq([ [ "lot_mismatch" ], [ "lot_mismatch" ], [] ])
      other_cnpj = Cnpj.with_check_digits("998887770001")
      expect(codes_of(row(lote: "X-3"), row(line: 3, cnes: "7654321", lote: "X-3", cnpj_fabricante: other_cnpj)))
        .to all(eq([ "lot_mismatch" ]))
      expect(codes_of(row(lote: "X-4"), row(line: 3, cnes: "7654321", lote: "X-4", registro_anvisa: "9876543210123")))
        .to all(eq([ "lot_mismatch" ]))
    end

    it "(a) só o preço diferente, ou um campo vazio numa das linhas, não é conflito" do
      expect(codes_of(row(lote: "Y-1"), row(line: 3, cnes: "7654321", lote: "Y-1", valor_unitario: "9,99"))).to eq([ [], [] ])
      expect(codes_of(row(lote: "Y-2"), row(line: 3, cnes: "7654321", lote: "Y-2", registro_anvisa: nil, programa: nil))).to eq([ [], [] ])
    end

    it "(a) vacina: a manufacturer_key diferente é conflito" do
      serum_cnpj = Cnpj.with_check_digits("998887770001")
      both = product.with(manufacturers: product.manufacturers.map do |m|
        m.with(cnpj: { "fiocruz" => fiocruz_cnpj, "serum" => serum_cnpj }[m.key])
      end)
      allow(Vaccination::Immunobiologicals).to receive(:find).with("15").and_return(both)
      expect(codes_of(vaccine_row, vaccine_row(line: 3, cnes: "7654321", cnpj_fabricante: serum_cnpj))).to all(eq([ "lot_mismatch" ]))
    end

    it "(b) linha divergente de um lote já gravado na cidade; o preço pode trocar" do
      lot = stocked_lot!(central, item: losartana, lot_number: "S-1", expires_on: Time.zone.today + 200)
      bnafar_complete!(lot)
      expect(codes_of(row(cnes: "7654321", lote: "S-1", validade: later))).to eq([ [ "lot_mismatch" ] ])
      expect(codes_of(row(cnes: "7654321", lote: "S-1", registro_anvisa: "9876543210123"))).to eq([ [ "lot_mismatch" ] ])
      expect(codes_of(row(cnes: "7654321", lote: "S-1", programa: "AFB", valor_unitario: "3,00"))).to eq([ [] ])
    end
  end

  it "program_unknown" do
    expect(codes_of(row(programa: "NAOEXISTE"))).to eq([ [ "program_unknown" ] ])
  end

  it "manufacturer_not_in_catalog: na vacina o CNPJ resolve o fabricante do YAML (Q21)" do
    expect(codes_of(vaccine_row(cnpj_fabricante: Cnpj.with_check_digits("998887770001")))).to eq([ [ "manufacturer_not_in_catalog" ] ])
    expect(codes_of(vaccine_row(cnpj_fabricante: nil))).to eq([ [ "manufacturer_not_in_catalog" ] ])
  end

  it "manufacturer_not_in_catalog com o YAML real (CNPJ nulo até o go-live, R8)" do
    allow(Vaccination::Immunobiologicals).to receive(:find).with("15").and_return(product)
    expect(codes_of(vaccine_row)).to eq([ [ "manufacturer_not_in_catalog" ] ])
  end

  it "duplicate_line: o mesmo lote do mesmo item no mesmo local outra vez" do
    expect(codes_of(row(lote: "D-1"), row(line: 3, lote: "D-1", quantidade: "5"), row(line: 4, lote: "D-2"))).to eq([ [], [ "duplicate_line" ], [] ])
  end

  it "opening_exists: o item já tem abertura ativa no local (R9)" do
    stocked_lot!(central, item: losartana)
    expect(codes_of(row, row(line: 3, cnes: "7654321"))).to eq([ [ "opening_exists" ], [] ])
    StockOpening.update_all(reverted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    expect(codes_of(row)).to eq([ [] ])
  end

  it "too_many_lots: mais de 100 lotes de um item num local" do
    rows = (1..101).map { |n| row(line: n + 1, lote: "L-#{n}") }
    expect(codes_of(*rows)).to all(eq([ "too_many_lots" ]))
    expect(codes_of(*rows.first(100))).to all(eq([]))
  end

  it "uma linha junta todos os seus códigos" do
    expect(codes_of(row(lote: "LOTE 1", validade: "ontem", quantidade: "0", programa: "X")).sole)
      .to eq(%w[invalid_lot_number invalid_date invalid_quantity program_unknown])
  end

  describe "campos de envio (Q26)" do
    let(:bare) { row(valor_unitario: nil, cnpj_fabricante: nil, registro_anvisa: nil, programa: nil) }

    it "domínio fora do envio: a linha sem os campos é válida e conta como aviso" do
      expect(validate(bare).sole).to have_attributes(status: "valid", send_fields_missing: true)
    end

    it "domínio no envio: os campos faltando são erro da linha, salvo o CNPJ vazio (Q38)" do
      expect(codes_of(bare, required: [ med ])).to eq([ %w[invalid_price invalid_anvisa program_unknown] ])
      expect(codes_of(row, required: [ med ])).to eq([ [] ])
    end

    it "CNPJ vazio no domínio do envio: a linha é válida e conta no aviso (Q38)" do
      expect(validate(row(cnpj_fabricante: nil), required: [ med ]).sole).to have_attributes(status: "valid", send_fields_missing: true)
      expect(codes_of(row(cnpj_fabricante: "123"), required: [ med ])).to eq([ [ "invalid_cnpj" ] ])
    end
  end
end
