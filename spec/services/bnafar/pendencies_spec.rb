require "rails_helper"

# Módulo 27b, Task 10 (contrato §3; Q7, Q15, Q16, Q21, Q22): o que impede o
# envio, calculado na leitura, sem pessoa. Cada pendência traz o local, o item
# e o lote, com `location_name` e `item_label`.
RSpec.describe Bnafar::Pendencies, type: :model do
  before { pharmacy_city! }
  let(:med) { Stock::Domain::MEDICATION }
  let(:vector) { Stock::Domain::VECTOR_CONTROL }
  let(:vaccine) { Stock::Domain::IMMUNOBIOLOGICAL }
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }

  def rows(domains: [ med, vector, vaccine ]) = Bnafar::Snapshot.call(reference_on: Time.zone.today, domains: domains, cutoff: Time.current)
  def found(domains: [ med, vector, vaccine ]) = described_class.call(rows: rows(domains: domains))
  def codes(list) = list.map { |pendency| [ pendency.code, pendency.stock_lot_id ] }

  def complete_med_lot!(quantity: "10", **over)
    losartana.update_columns(vmp_code: "@brasil1000")
    bnafar_complete!(stocked_lot!(central, item: losartana, quantity: quantity, **over), ampp_code: "@brasil20038375080")
  end

  it "lote completo não tem pendência" do
    complete_med_lot!
    expect(found).to eq([])
  end

  it "lote sem preço → lot_incomplete com fields" do
    lot = complete_med_lot!
    other = stocked_lot!(central, item: losartana, quantity: "5")
    bnafar_complete!(other, ampp_code: "@brasil20038375081", unit_price_cents: nil)

    expect(found.map(&:to_h)).to eq([ { code: "lot_incomplete", stock_location_id: central.id, location_name: central.name,
                                        item_key: "medication:#{losartana.id}", item_label: losartana.label, stock_lot_id: other.id, lot_id: other.id, lot_number: other.lot_number, lot_version: other.bnafar_version,
                                        fields: [ "unit_price_cents" ] } ])
    expect(codes(found)).not_to include([ "lot_incomplete", lot.id ])
  end

  it "lote de 31 caracteres → lot_number_too_long" do
    losartana.update_columns(vmp_code: "@brasil1000")
    lot = bnafar_complete!(stocked_lot!(central, item: losartana, lot_number: "L" * 31), ampp_code: "@brasil20038375080")

    expect(found.map { |pendency| [ pendency.code, pendency.stock_lot_id, pendency.fields ] }).to eq([ [ "lot_number_too_long", lot.id, [ "lot_number" ] ] ])
  end

  it "frasco aberto (25 doses de frasco de 10) → fractional_balance" do
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    lot = vaccine_lot!(cold, code: "15", doses: 25)

    expect(codes(found(domains: [ vaccine ]))).to include([ "fractional_balance", lot.id ])
  end

  # Revisão final: o produto que saiu do YAML é `product_without_code`
  # (obm_vmp), não `fractional_balance` (o frasco não é conhecido, não há fração).
  it "vacina com código fora do YAML → product_without_code, sem fractional_balance; o resto da cidade segue limpo" do
    med_lot = complete_med_lot!
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    gone = vaccine_lot!(cold, code: "ZZ99", doses: 30)

    list = found
    expect(list.select { |pendency| pendency.stock_lot_id == gone.id }.map { |pendency| [ pendency.code, pendency.fields ] })
      .to include([ "product_without_code", [ "obm_vmp" ] ])
    expect(codes(list)).not_to include([ "fractional_balance", gone.id ])
    expect(described_class.clean(rows).map { |row| row.lot.id }).to eq([ med_lot.id ])
  end

  it "central sem CNES → location_without_cnes" do
    lot = complete_med_lot!
    central.update_columns(cnes: nil)

    expect(found.map { |pendency| [ pendency.code, pendency.stock_location_id, pendency.stock_lot_id, pendency.fields ] })
      .to eq([ [ "location_without_cnes", central.id, lot.id, [ "cnes" ] ] ])
  end

  it "medicamento sem VMP → product_without_code; vacina sem obm_vmp e vetorial sem CATMAT também" do
    lot = bnafar_complete!(stocked_lot!(central, item: losartana))
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    vaccine_lot = bnafar_complete!(vaccine_lot!(cold, code: "15", doses: 20))
    place = vector_location!(create_unit("UVZ Pendência", kind: "environmental_surveillance", cnes: "4444444"))
    vector_lot = bnafar_complete!(vector_lot!(place, product: vector_product!))

    list = found
    expect(list.select { |pendency| pendency.code == "product_without_code" }.map { |pendency| [ pendency.stock_lot_id, pendency.fields ] })
      .to contain_exactly([ lot.id, [ "vmp_code" ] ], [ vaccine_lot.id, [ "obm_vmp" ] ], [ vector_lot.id, [ "catmat_code" ] ])
  end

  it "vacina com obm_vmp mas fabricante sem CNPJ no YAML → lot_incomplete com manufacturer_cnpj (Q21)" do
    product = Vaccination::Immunobiologicals.find("15")
    allow(Vaccination::Immunobiologicals).to receive(:find).and_call_original
    allow(Vaccination::Immunobiologicals).to receive(:find).with("15").and_return(product.with(obm_vmp: "@brasil7000"))
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    lot = bnafar_complete!(vaccine_lot!(cold, code: "15", doses: 20, manufacturer_key: product.manufacturers.first.key), ampp_code: "@brasil70001")

    expect(found(domains: [ vaccine ]).map { |pendency| [ pendency.code, pendency.stock_lot_id, pendency.fields ] })
      .to eq([ [ "lot_incomplete", lot.id, [ "manufacturer_cnpj" ] ] ])
  end

  it "saída sem tipo → exit_type_missing" do
    lot = complete_med_lot!
    movement = StockMovement.find_by!(stock_lot_id: lot.id)
    row = Bnafar::Exits::Row.new(movement: movement, cnes: "1234567", type: "A", exit_type: nil, destination: "1234567", lot: lot, quantity: 1)

    expect(described_class.call(rows: [ row ]).map(&:code)).to eq([ "exit_type_missing" ])
  end

  describe ".current" do
    let(:place) { vector_location!(create_unit("UVZ Atual", kind: "environmental_surveillance", cnes: "4444444")) }

    it "vetorial com bnafar_vector_supplies desligado → domain_off; o resto do vetorial também aparece" do
      complete_med_lot!
      lot = vector_lot!(place, product: vector_product!)

      list = described_class.current(domains_all: [ med, vector ], domains_on: [ med ])
      expect(codes(list)).to include([ "domain_off", lot.id ], [ "lot_incomplete", lot.id ])
      expect(list.map(&:code)).to all(satisfy { |code| Bnafar::Catalog::PENDENCY_CODES.include?(code) })
    end

    it "bnafar inutilizável (domains_on: nil, Q22) → conta contra os domínios do estoque, sem domain_off" do
      lot = vector_lot!(place, product: vector_product!)

      list = described_class.current(domains_all: [ med, vector ], domains_on: nil)
      expect(codes(list)).to include([ "lot_incomplete", lot.id ])
      expect(list.map(&:code)).not_to include("domain_off")
    end

    it "inclui as saídas de ontem e hoje (destino sem CNES), sem repetir a mesma pendência" do
      lot = complete_med_lot!(quantity: "20")
      unit = unit_location!(create_unit("UBS Sem CNES Atual"))
      2.times do
        result = Pharmacy::SendTransfer.call(from: central, to: unit, items: [ { "lot_id" => lot.id, "quantity" => "2" } ], by: pharmacy_admin!)
        raise result.inspect if result.failure?
      end

      list = described_class.current(domains_all: [ med ], domains_on: [ med ])
      expect(list.map { |pendency| [ pendency.code, pendency.stock_location_id ] }).to eq([ [ "location_without_cnes", unit.id ] ])
    end
  end

  it "toda pendência tem location_name e item_label, nenhuma traz pessoa" do
    stocked_lot!(central, item: losartana, lot_number: "L" * 31)
    central.update_columns(cnes: nil)
    cold = cold_chain_central!
    vaccine_lot!(cold, code: "15", doses: 25)

    list = found
    expect(list.size).to be >= 4
    expect(list.map { |pendency| pendency.to_h.keys }.uniq).to eq([ %i[code stock_location_id location_name item_key item_label stock_lot_id fields lot_id lot_number lot_version] ])
    expect(list).to all(have_attributes(location_name: be_present, item_label: be_present))
    text = list.map(&:to_h).to_s
    expect(text).not_to match(/patient|citizen|cpf|cns|user/i)
  end
end
