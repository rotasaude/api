require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)

# Módulo 32b, Task 10 (ADR 0050; contrato §6 e §12 Q6; plano, Desvio 7; R7):
# a baixa da checagem pelo FEFO no local `unit` ativo da UPA, um lote só por
# administração, e as faltas no_location / insufficient_balance /
# lot_unavailable. Pela via real (Urgency::RecordAdministration com `stock:
# true`); `now:` anda pelos horários do aprazamento de 8 em 8 h.
RSpec.describe Urgency::DeductStock do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:doctor) { observation_doctor!(upa) }
  let(:nurse) { observation_nurse!(upa) }
  let!(:catalog) { import_test_catalog! }
  let(:losartana) { catalog_item(268_856) }
  let(:diazepam) { catalog_item(267_197) }
  let(:encounter) { in_care_encounter!(upa).tap { |e| urgency_consultation!(e, doctor: doctor) } }
  let(:location) { unit_location!(upa) }
  let(:today) { Time.zone.today }
  let(:item) { issue!.items.first }
  let(:shortfall_events) { DomainEvent.where(name: "urgency.stock_shortfall_recorded") }

  before do
    ciap2_release!; cid10_release!; sigtap_release!
    pharmacy_city!
    location
  end

  after { Current.reset }

  def issue!(**over)
    row = { catalog_item_id: losartana.id, dose: "50", dose_unit: "mg", route: "oral", frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
    result = Urgency::IssuePrescription.call(encounter: encounter, items: [ row.deep_stringify_keys ], by: doctor,
                                             catalog: { losartana.id => losartana, diazepam.id => diazepam })
    raise "issue! recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:prescription)
  end

  # O horário `slot` do aprazamento, checado "na hora" (now = o horário).
  def result!(row, slot: 0, status: "administered", **body)
    at = row.first_dose_at + (slot * 8).hours
    attrs = { "prescription_item_id" => row.id, "scheduled_at" => at.iso8601, "status" => status }.merge(body.deep_stringify_keys)
    Urgency::RecordAdministration.call(attrs: attrs, by: nurse, stock: true, now: at)
  end

  def record!(row, **)
    result = result!(row, **)
    raise "recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:administration).reload
  end

  def other_unit_lot!(number = "UN#{SecureRandom.hex(2)}")
    StockLot.create!(catalog_item_id: losartana.id, catmat_code: losartana.catmat_code, lot_number: number, expires_on: today + 60,
                     dispensing_unit: "frasco", created_by_user: pharmacy_admin!)
    lot!(location, item: losartana, quantity: "9", lot_number: number, expires_on: today + 60)
  end


  # Lote do medicamento na unidade de dispensação do item da prescrição
  # (`stock_unit`, a do catálogo; a amostra de teste cai em "unidade"), com
  # saldo no local pelo caminho real (stocked_lot!).
  def lot!(location, item:, quantity: "30", lot_number: "L#{SecureRandom.hex(3).upcase}", expires_on: today + 180,
           unit: Pharmacy::DispensingUnit.for(item))
    StockLot.find_by(catalog_item_id: item.id, lot_number: lot_number) ||
      StockLot.create!(catalog_item_id: item.id, catmat_code: item.catmat_code, lot_number: lot_number, expires_on: expires_on,
                       dispensing_unit: unit, created_by_user: pharmacy_admin!)
    stocked_lot!(location, item: item, quantity: quantity, lot_number: lot_number, expires_on: expires_on)
  end

  it "FEFO: o lote não vencido de menor validade com saldo; empate pelo número e pelo id" do
    late = lot!(location, item: losartana, quantity: "30", lot_number: "B2", expires_on: today + 300)
    early = lot!(location, item: losartana, quantity: "30", lot_number: "B1", expires_on: today + 30)
    lot!(location, item: losartana, quantity: "30", lot_number: "A0", expires_on: today - 1)
    expect(record!(item).stock_lot_id).to eq(early.id)
    expect(balance_of(location, early)).to eq(29)
    expect(balance_of(location, late)).to eq(30)

    tie = lot!(location, item: losartana, quantity: "30", lot_number: "A1", expires_on: today + 30)
    expect(record!(item, slot: 1).stock_lot_id).to eq(tie.id)
  end

  it "grava UM movimento administration do lote, com a administração como documento, e a quantidade por dose como padrão" do
    lot = lot!(location, item: losartana, quantity: "10")
    row = issue!(stock_quantity_per_dose: "2.5").items.first
    adm = nil
    expect { adm = record!(row) }.to change(StockMovement, :count).by(1).and(not_change(UrgencyStockShortfall, :count))
    expect(adm).to have_attributes(stock_lot_id: lot.id, stock_quantity: BigDecimal("2.5"))
    expect(adm.stock_movement).to have_attributes(kind: "administration", stock_location_id: location.id, stock_lot_id: lot.id,
                                                  quantity: BigDecimal("-2.5"), catalog_item_id: losartana.id, recorded_by_user_id: nurse.id)
    expect(balance_of(location, lot)).to eq(BigDecimal("7.5"))
    expect(adm.shortfall).to be_nil
    expect(shortfall_events).to be_empty
  end

  it "sem local unit ativo: a administração fica e nasce no_location sem local" do
    location.update!(active: false)
    adm = record!(item)
    expect(adm.stock_lot_id).to be_nil
    expect(adm.stock_quantity).to be_nil
    expect(adm.shortfall).to have_attributes(cause: "no_location", stock_location_id: nil, quantity: 1, catalog_item_id: losartana.id)
    expect(shortfall_events.sole.payload).to eq("shortfall_id" => adm.shortfall.id)
  end

  it "o local desativado entre a leitura e a trava (Ledger::Inactive) → no_location" do
    stale = StockLocation.find(location.id)
    lot!(location, item: losartana, quantity: "5")
    location.update!(active: false)
    allow(Urgency::Fefo).to receive(:location_for).and_return(stale)
    adm = nil
    expect { adm = record!(item) }.not_to change(StockMovement, :count)
    expect(adm.shortfall).to have_attributes(cause: "no_location", stock_location_id: nil)
  end

  it "sem lote com saldo suficiente: insufficient_balance; o lote do corpo curto: lot_unavailable; vencido: 422 lot_invalid" do
    lot = lot!(location, item: losartana, quantity: "1")
    expect(record!(item, stock_quantity: "2").shortfall.cause).to eq("insufficient_balance")
    expect(record!(item, slot: 1, stock_lot_id: lot.id, stock_quantity: "2").shortfall.cause).to eq("lot_unavailable")
    old = lot!(location, item: losartana, quantity: "5", expires_on: today - 1)
    expect(result!(item, slot: 2, stock_lot_id: old.id).reason).to eq(:lot_invalid)
    expect(balance_of(location, lot)).to eq(1)
  end

  it "um lote só, sem fracionar: dois lotes de 1 não somam a dose de 2" do
    lot!(location, item: losartana, quantity: "1", expires_on: today + 10)
    lot!(location, item: losartana, quantity: "1", expires_on: today + 20)
    adm = nil
    expect { adm = record!(item, stock_quantity: "2") }.not_to change(StockMovement, :count)
    expect(adm.shortfall).to have_attributes(cause: "insufficient_balance", stock_location_id: location.id, quantity: 2)
    expect(shortfall_events.sole.payload).to eq("shortfall_id" => adm.shortfall.id)
  end

  it "o FEFO ignora o lote de outra unidade de dispensação e o bloqueado; no corpo, os dois → 422 lot_invalid sem gravar nada" do
    other = other_unit_lot!
    blocked = lot!(location, item: losartana, quantity: "9")
    lot_block!(location, blocked)
    adm = record!(item)
    expect(adm.stock_lot_id).to be_nil
    expect(adm.shortfall.cause).to eq("insufficient_balance")

    [ other, blocked ].each do |lot|
      expect { expect(result!(item, slot: 1, stock_lot_id: lot.id).reason).to eq(:lot_invalid) }
        .to not_change(UrgencyAdministration, :count).and(not_change(StockMovement, :count)).and(not_change(UrgencyStockShortfall, :count))
    end
    expect(result!(item, slot: 1, stock_lot_id: blocked.id).details).to include(path: "stock_lot_id")
  end

  it "no corpo: lote de outro item, inexistente ou de outro local (sem movimento no local da UPA) → 422 lot_invalid" do
    other_item = lot!(location, item: diazepam, quantity: "5")
    central_only = lot!(central_location!, item: losartana, quantity: "5")
    [ other_item.id, SecureRandom.uuid, central_only.id ].each do |id|
      expect(result!(item, stock_lot_id: id).reason).to eq(:lot_invalid)
    end
    expect(UrgencyAdministration.count).to eq(0)
  end

  # §12 Q12 (corrige o §6 item 2): o lote do corpo válido mas já consumido não recusa a checagem.
  it "o lote do corpo já consumido (saldo 0) → o próximo lote do FEFO, sem falta" do
    chosen = lot!(location, item: losartana, quantity: "1", expires_on: today + 5)
    next_lot = lot!(location, item: losartana, quantity: "4", expires_on: today + 40)
    lot!(location, item: losartana, quantity: "4", expires_on: today + 90)
    expect(record!(item, stock_lot_id: chosen.id).stock_lot_id).to eq(chosen.id)
    expect(balance_of(location, chosen)).to eq(0)

    adm = nil
    expect { adm = record!(item, slot: 1, stock_lot_id: chosen.id) }.to change(StockMovement, :count).by(1)
    expect(adm.stock_lot_id).to eq(next_lot.id)
    expect(adm.shortfall).to be_nil
    expect(balance_of(location, next_lot)).to eq(3)
    expect(balance_of(location, chosen)).to eq(0)
  end

  it "o lote do corpo curto (0 < saldo < quantidade) → o próximo lote do FEFO com saldo suficiente" do
    short = lot!(location, item: losartana, quantity: "1", expires_on: today + 5)
    lot!(location, item: losartana, quantity: "1", expires_on: today + 10)
    enough = lot!(location, item: losartana, quantity: "3", expires_on: today + 60)
    adm = record!(item, stock_lot_id: short.id, stock_quantity: "2")
    expect(adm).to have_attributes(stock_lot_id: enough.id, stock_quantity: 2)
    expect(balance_of(location, short)).to eq(1)
    expect(balance_of(location, enough)).to eq(1)
  end

  it "o lote do corpo já consumido e nenhum outro com saldo → 201 sem lote, com a falta lot_unavailable" do
    chosen = lot!(location, item: losartana, quantity: "1")
    record!(item, stock_lot_id: chosen.id)
    adm = nil
    expect { adm = record!(item, slot: 1, stock_lot_id: chosen.id) }
      .to change(UrgencyStockShortfall, :count).by(1).and(not_change(StockMovement, :count))
    expect(adm).to have_attributes(stock_lot_id: nil, stock_quantity: nil)
    expect(adm.shortfall).to have_attributes(cause: "lot_unavailable", stock_location_id: location.id, quantity: 1)
    expect(shortfall_events.sole.payload).to eq("shortfall_id" => adm.shortfall.id)
    expect(balance_of(location, chosen)).to eq(0)
  end

  it "a rede do trigger (Ledger::Insufficient no record!) → o savepoint volta e a administração fica sem lote, com lot_unavailable" do
    lot = lot!(location, item: losartana, quantity: "1")
    # A conta da aplicação enxerga saldo de sobra; o trigger do banco recusa.
    allow(Pharmacy::Ledger).to receive(:balances).and_return({ lot.id => BigDecimal("100") })
    allow(Pharmacy::Ledger).to receive(:balance).and_return(BigDecimal("100"))
    adm = nil
    expect { adm = record!(item, stock_lot_id: lot.id, stock_quantity: "2") }
      .to change(UrgencyAdministration, :count).by(1).and(not_change(StockMovement, :count))
    expect(adm).to have_attributes(stock_lot_id: nil, stock_quantity: nil)
    expect(adm.shortfall).to have_attributes(cause: "lot_unavailable", stock_location_id: location.id, quantity: 2)
    expect(balance_of(location, lot)).to eq(1)
  end

  it "fora de administered (o interruptor utilizável): sem movimento nem falta" do
    lot!(location, item: losartana, quantity: "5")
    expect { record!(item, status: "refused", reason: "Paciente recusou a medicação") }
      .to not_change(StockMovement, :count).and(not_change(UrgencyStockShortfall, :count))
  end

  it "controlado (diazepam B1) baixa como qualquer item (P1)" do
    lot = lot!(location, item: diazepam, quantity: "10")
    row = issue!(catalog_item_id: diazepam.id, dose: "5").items.first
    expect(row.controlled_list).to be_present
    adm = record!(row)
    expect(adm.stock_movement).to have_attributes(kind: "administration", stock_lot_id: lot.id, quantity: -1)
  end

  it "stock_quantity como número JSON, zero ou com três casas → 422 invalid_request; stock_lot_id malformado → 422 invalid_request" do
    lot!(location, item: losartana, quantity: "5")
    [ 1, "0", "1.234", "-1" ].each do |raw|
      result = result!(item, stock_quantity: raw)
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "stock_quantity" ])
    end
    result = result!(item, stock_lot_id: "abc")
    expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "stock_lot_id" ])
    expect(UrgencyAdministration.count).to eq(0)
  end
end
