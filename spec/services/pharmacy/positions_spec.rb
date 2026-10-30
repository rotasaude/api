require "rails_helper"

# Módulo 27a, Task 8 (ADR 0045; contrato §2, §4 e H10/H12): a posição por
# (local, item). O saldo é a soma dos movimentos; "em trânsito" é derivado dos
# itens de transferências `sent`. Cada lote traz as marcas `expired` e
# `expiring_soon`; a posição, `expiring_soon` e `below_minimum`.
RSpec.describe Pharmacy::Positions do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }
  let(:losartana) { catalog_item(268_856) }
  let(:amoxicilina) { catalog_item(271_089) }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:today) { Time.zone.today }
  let(:settings) { Pharmacy::Settings.current }

  def call(location_ids: [ central.id, farmacia.id ], limit: 50, **options)
    described_class.call(location_ids: location_ids, limit: limit, today: today, settings: settings, **options)
  end

  def of(result, location, item) = result[:positions].find { |row| row.dig(:location, :id) == location.id && row.dig(:item, :catalog_item_id) == item.id }
  def lot_flags(position) = position[:lots].to_h { |row| [ row.dig(:lot, :lot_number), row.values_at(:balance, :in_transit, :expiring_soon, :expired) ] }

  def send_to_unit!(*lines)
    result = Pharmacy::SendTransfer.call(from: central, to: farmacia, items: lines.map { |lot, quantity| { "lot_id" => lot.id, "quantity" => quantity } },
                                         by: keeper, now: Time.current)
    raise result.inspect if result.failure?

    result.payload.fetch(:transfer)
  end

  # Lote gravado com a unidade de dispensação pedida (a coluna é só-anexo: não dá UPDATE);
  # o `stocked_lot!` seguinte reaproveita o lote pelo número.
  def lot_with_unit!(item, lot_number, unit, expires_on)
    StockLot.create!(catalog_item_id: item.id, catmat_code: item.catmat_code, lot_number: lot_number, expires_on: expires_on,
                     dispensing_unit: unit, created_by_user: pharmacy_admin!)
  end

  def minimum!(location, item, value) = StockMinimum.create!(stock_location: location, catalog_item_id: item.id, minimum: value, updated_by_user: keeper)

  it "dois lotes no central e um em trânsito para a UBS: saldo somado no central; na UBS, em trânsito e saldo 0.00" do
    first = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "A-1", expires_on: today + 200)
    stocked_lot!(central, item: paracetamol, quantity: "30", lot_number: "A-2", expires_on: today + 300)
    send_to_unit!([ first, "40" ])

    result = call
    central_position = of(result, central, paracetamol)
    expect(central_position[:balance]).to eq("50.00")
    expect(lot_flags(central_position)).to eq("A-1" => [ "20.00", "0.00", false, false ], "A-2" => [ "30.00", "0.00", false, false ])
    expect(central_position[:lots].map { |row| row.dig(:lot, :lot_number) }).to eq(%w[A-1 A-2])

    unit_position = of(result, farmacia, paracetamol)
    expect(unit_position[:balance]).to eq("0.00")
    expect(lot_flags(unit_position)).to eq("A-1" => [ "0.00", "40.00", false, false ])
    expect(unit_position).to include(minimum: nil, below_minimum: false, expiring_soon: false)
    expect(result[:next_before]).to be_nil
  end

  it "em trânsito é só o que está sent: depois do recebimento sai do em trânsito e entra no saldo" do
    lot = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "T-1")
    transfer = send_to_unit!([ lot, "40" ])
    Pharmacy::ReceiveTransfer.call(transfer: transfer, items: [ { "lot_id" => lot.id, "quantity_received" => "40" } ], by: pharmacy_staff!(farmacia, "pharmacist"),
                                   now: Time.current)

    unit_position = of(call, farmacia, paracetamol)
    expect(unit_position[:balance]).to eq("40.00")
    expect(lot_flags(unit_position)).to eq("T-1" => [ "40.00", "0.00", false, false ])
  end

  it "lote esgotado no central que já teve movimento continua em lots[] com saldo 0.00; na UBS vem em trânsito" do
    lot = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "Z-1")
    send_to_unit!([ lot, "60" ])

    result = call
    expect(of(result, central, paracetamol)).to include(balance: "0.00")
    expect(lot_flags(of(result, central, paracetamol))).to eq("Z-1" => [ "0.00", "0.00", false, false ])
    expect(lot_flags(of(result, farmacia, paracetamol))).to eq("Z-1" => [ "0.00", "60.00", false, false ])
  end

  it "lote zerado por baixa, com as marcas normais, fica em lots[] ao lado do lote com saldo" do
    gone = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "GONE", expires_on: today + 20)
    stocked_lot!(central, item: paracetamol, quantity: "30", lot_number: "LIVE", expires_on: today + 300)
    Pharmacy::RequestAdjustment.call(location: central, lot: gone, kind: "loss", counted_quantity: nil, quantity: "10",
                                     reason: "Frascos quebrados no armário", by: keeper, settings: settings)

    position = of(call(location_ids: [ central.id ]), central, paracetamol)
    expect(position[:balance]).to eq("30.00")
    expect(lot_flags(position)).to eq("GONE" => [ "0.00", "0.00", true, false ], "LIVE" => [ "30.00", "0.00", false, false ])
  end

  it "lote que nunca teve movimento nem trânsito no local não aparece, mesmo existindo em outro local" do
    stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "ONLY-CENTRAL")
    stocked_lot!(farmacia, item: paracetamol, quantity: "5", lot_number: "ONLY-UBS")

    expect(lot_flags(of(call, farmacia, paracetamol))).to eq("ONLY-UBS" => [ "5.00", "0.00", false, false ])
    expect(lot_flags(of(call, central, paracetamol))).to eq("ONLY-CENTRAL" => [ "60.00", "0.00", false, false ])
  end

  it "marcas por lote: vencido (validade < hoje), vencendo (hoje até hoje + 90) e em dia; a posição marca expiring_soon com lote vencendo ou vencido" do
    stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "OLD", expires_on: today - 2)
    stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TODAY", expires_on: today)
    stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "D60", expires_on: today + 60)
    stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "D90", expires_on: today + 90)
    stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "D91", expires_on: today + 91)
    stocked_lot!(central, item: losartana, quantity: "10", lot_number: "L-OLD", expires_on: today - 1)
    stocked_lot!(central, item: amoxicilina, quantity: "10", lot_number: "FAR", expires_on: today + 91)

    result = call(location_ids: [ central.id ])
    expect(lot_flags(of(result, central, paracetamol))).to eq(
      "OLD" => [ "10.00", "0.00", false, true ], "TODAY" => [ "10.00", "0.00", true, false ], "D60" => [ "10.00", "0.00", true, false ],
      "D90" => [ "10.00", "0.00", true, false ], "D91" => [ "10.00", "0.00", false, false ]
    )
    expect(of(result, central, paracetamol)[:expiring_soon]).to be(true)
    expect(of(result, central, losartana)).to include(expiring_soon: true)
    expect(of(result, central, losartana)[:lots].sole).to include(expired: true, expiring_soon: false)
    expect(of(result, central, amoxicilina)[:expiring_soon]).to be(false)
  end

  it "o limite de alerta vem dos parâmetros da cidade (expiry_alert_days)" do
    stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "D60", expires_on: today + 60)
    expect(of(call, central, paracetamol)[:expiring_soon]).to be(true)
    settings.class.where(id: 1).update_all(expiry_alert_days: 30)
    expect(of(call(settings: Pharmacy::Settings.current), central, paracetamol)[:expiring_soon]).to be(false)
  end

  it "lote vencido sem saldo continua em lots[] (expired true, saldo 0.00) mas não marca a posição como vencendo" do
    lot = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "OLD", expires_on: today - 2)
    Pharmacy::RequestAdjustment.call(location: central, lot: lot, kind: "expiry", counted_quantity: nil, quantity: "10",
                                     reason: "Lote vencido descartado", by: keeper, settings: settings)

    position = of(call, central, paracetamol)
    expect(position).to include(balance: "0.00", expiring_soon: false)
    expect(lot_flags(position)).to eq("OLD" => [ "0.00", "0.00", false, true ])
  end

  it "mínimo 50 com saldo 40 → below_minimum; saldo 50 não; mínimo 0 vira minimum null" do
    stocked_lot!(central, item: paracetamol, quantity: "40", lot_number: "M-1")
    stocked_lot!(central, item: losartana, quantity: "50", lot_number: "M-2")
    stocked_lot!(central, item: amoxicilina, quantity: "1", lot_number: "M-3")
    minimum!(central, paracetamol, 50)
    minimum!(central, losartana, 50)
    minimum!(central, amoxicilina, 0)

    result = call(location_ids: [ central.id ])
    expect(of(result, central, paracetamol)).to include(minimum: "50.00", below_minimum: true, balance: "40.00")
    expect(of(result, central, losartana)).to include(minimum: "50.00", below_minimum: false)
    expect(of(result, central, amoxicilina)).to include(minimum: nil, below_minimum: false)
  end

  it "item com mínimo e sem movimento entra com saldo 0.00 e abaixo do mínimo; mínimo 0 sem movimento não entra" do
    minimum!(farmacia, amoxicilina, 20)
    minimum!(farmacia, losartana, 0)

    result = call(location_ids: [ farmacia.id ])
    expect(result[:positions].size).to eq(1)
    expect(of(result, farmacia, amoxicilina)).to include(balance: "0.00", lots: [], minimum: "20.00", below_minimum: true, expiring_soon: false)
    expect(of(result, farmacia, amoxicilina)[:item]).to include(catalog_item_id: amoxicilina.id, dispensing_unit: Pharmacy::DispensingUnit.for(amoxicilina))
  end

  it "a UBS com o mesmo item em trânsito conta o saldo do lote só uma vez e o mínimo é do local" do
    lot = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "U-1")
    minimum!(central, paracetamol, 10)
    minimum!(farmacia, paracetamol, 30)
    send_to_unit!([ lot, "20" ])

    result = call
    expect(of(result, central, paracetamol)).to include(balance: "40.00", minimum: "10.00", below_minimum: false)
    expect(of(result, farmacia, paracetamol)).to include(balance: "0.00", minimum: "30.00", below_minimum: true)
  end

  describe "paginação por (local, item)" do
    before do
      stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "P-1")
      stocked_lot!(central, item: losartana, quantity: "10", lot_number: "P-2")
      stocked_lot!(farmacia, item: amoxicilina, quantity: "10", lot_number: "P-3")
    end

    def keys(result) = result[:positions].map { |row| [ row.dig(:location, :id), row.dig(:item, :catalog_item_id) ] }
    def cursor_of(token) = Pharmacy::Cursor.decode(token)

    it "limit 1 devolve next_before e cada página traz o seguinte, sem repetir, na ordem (local, item)" do
      expected = [ [ central.id, paracetamol.id ], [ central.id, losartana.id ], [ farmacia.id, amoxicilina.id ] ].sort
      seen = []
      token = nil
      4.times do
        page = call(limit: 1, before: token && cursor_of(token))
        seen.concat(keys(page))
        token = page[:next_before]
        break unless token

        expect(page[:positions].size).to eq(1)
        expect(cursor_of(token)).to eq(keys(page).last)
      end
      expect(token).to be_nil
      expect(seen).to eq(expected)
    end

    it "página cheia que acaba exatamente na última posição não traz next_before" do
      page = call(limit: 3)
      expect([ page[:positions].size, page[:next_before] ]).to eq([ 3, nil ])
    end

    it "os filtros rodam antes do limite: com limit 1 a única posição vencendo vem na primeira página, sem next_before" do
      stocked_lot!(central, item: amoxicilina, quantity: "5", lot_number: "P-4", expires_on: today + 10)
      page = call(limit: 1, expiring: true)
      expect(keys(page)).to eq([ [ central.id, amoxicilina.id ] ])
      expect(page[:next_before]).to be_nil
    end

    it "expiring=true não traz a posição cuja única pendência é um lote zerado vencido; com saldo vencendo ela entra" do
      old = stocked_lot!(central, item: amoxicilina, quantity: "5", lot_number: "P-OLD", expires_on: today - 3)
      Pharmacy::RequestAdjustment.call(location: central, lot: old, kind: "expiry", counted_quantity: nil, quantity: "5",
                                       reason: "Lote vencido descartado", by: keeper, settings: settings)
      expect(keys(call(expiring: true))).to eq([])
      expect(keys(call)).to include([ central.id, amoxicilina.id ])

      stocked_lot!(central, item: amoxicilina, quantity: "2", lot_number: "P-SOON", expires_on: today + 10)
      expect(keys(call(expiring: true))).to eq([ [ central.id, amoxicilina.id ] ])
    end

    def zeroed_amoxicilina!
      zeroed = stocked_lot!(central, item: amoxicilina, quantity: "5", lot_number: "P-ZERO")
      Pharmacy::RequestAdjustment.call(location: central, lot: zeroed, kind: "loss", counted_quantity: nil, quantity: "5",
                                       reason: "Frascos quebrados no armário", by: keeper, settings: settings)
    end

    it "below_minimum: o item só com lote zerado, com mínimo 8, está abaixo do mínimo e aparece no filtro" do
      zeroed_amoxicilina!
      minimum!(central, amoxicilina, 8)
      expect(keys(call(below_minimum: true))).to eq([ [ central.id, amoxicilina.id ] ])
    end

    it "below_minimum segue o saldo total: lote zerado ao lado de lote com saldo acima do mínimo não alerta, mas continua em lots[]" do
      zeroed_amoxicilina!
      stocked_lot!(central, item: amoxicilina, quantity: "10", lot_number: "P-FULL")
      minimum!(central, amoxicilina, 8)
      expect(keys(call(below_minimum: true))).to eq([])
      expect(lot_flags(of(call, central, amoxicilina)).keys).to match_array(%w[P-ZERO P-FULL])
    end

    it "dispensing_unit da posição vem do primeiro lote com estoque, não do lote zerado e vencido que lidera o FEFO" do
      lot_with_unit!(amoxicilina, "U-OLD", "frasco", today - 5)
      lot_with_unit!(amoxicilina, "U-LIVE", "capsula", today + 200)
      zeroed = stocked_lot!(central, item: amoxicilina, quantity: "5", lot_number: "U-OLD", expires_on: today - 5)
      stocked_lot!(central, item: amoxicilina, quantity: "7", lot_number: "U-LIVE", expires_on: today + 200)
      Pharmacy::RequestAdjustment.call(location: central, lot: zeroed, kind: "expiry", counted_quantity: nil, quantity: "5",
                                       reason: "Lote vencido descartado", by: keeper, settings: settings)

      position = of(call(location_ids: [ central.id ]), central, amoxicilina)
      expect(position[:lots].map { |row| row.dig(:lot, :lot_number) }).to eq(%w[U-OLD U-LIVE])
      expect(position[:lots].map { |row| row.dig(:lot, :item, :dispensing_unit) }).to eq(%w[frasco capsula])
      expect(position[:item][:dispensing_unit]).to eq("capsula")
    end

    it "dispensing_unit: sem lote com estoque cai para o primeiro lote; sem lotes, para o padrão do item" do
      lot_with_unit!(amoxicilina, "U-ONLY", "frasco", today + 180)
      zeroed = stocked_lot!(central, item: amoxicilina, quantity: "5", lot_number: "U-ONLY")
      Pharmacy::RequestAdjustment.call(location: central, lot: zeroed, kind: "loss", counted_quantity: nil, quantity: "5",
                                       reason: "Frascos quebrados no armário", by: keeper, settings: settings)
      minimum!(farmacia, losartana, 3)

      expect(of(call, central, amoxicilina)[:item][:dispensing_unit]).to eq("frasco")
      expect(of(call, farmacia, losartana)).to include(lots: [])
      expect(of(call, farmacia, losartana)[:item][:dispensing_unit]).to eq(Pharmacy::DispensingUnit.for(losartana))
    end

    it "catalog_item_ids e location_ids restringem; lista vazia de itens não traz nada" do
      expect(keys(call(catalog_item_ids: [ losartana.id ]))).to eq([ [ central.id, losartana.id ] ])
      expect(keys(call(location_ids: [ farmacia.id ]))).to eq([ [ farmacia.id, amoxicilina.id ] ])
      expect(call(catalog_item_ids: [])[:positions]).to eq([])
    end

    it "below_minimum filtra só os abaixo do mínimo (inclusive sem movimento)" do
      minimum!(central, paracetamol, 50)
      minimum!(farmacia, losartana, 5)
      expect(keys(call(below_minimum: true)).sort).to eq([ [ central.id, paracetamol.id ], [ farmacia.id, losartana.id ] ].sort)
    end
  end
end
