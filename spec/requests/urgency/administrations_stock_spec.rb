require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)

# Módulo 32b, Task 10 (ADR 0050; contrato §6 e §12 Q5, Q6; plano, Desvios 7 a
# 9; R7): POST /urgency/administrations com o interruptor
# `urgency_stock_deduction` utilizável — a baixa pelo FEFO no local `unit`
# ativo da UPA, um lote só, e a resposta `shortfall: null | { cause }`. A
# checagem nunca é recusada por falta de estoque; o lote do corpo inválido
# → 422 `lot_invalid` sem gravar nada. Duas checagens ao mesmo tempo do último
# comprimido: spec/commands/urgency/deduct_stock_concurrency_spec.rb.
RSpec.describe "Urgência — checagem da medicação com baixa de estoque", type: :request do
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
  let(:shortfall_events) { DomainEvent.where(name: "urgency.stock_shortfall_recorded") }

  before do
    ciap2_release!; cid10_release!; sigtap_release!
    pharmacy_city!
    Platform::Features.set!(city: city, key: Urgency::StockGate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    location
    sign_in_as(nurse)
  end

  after { Current.reset }

  def item(catalog_item = losartana, **over)
    { catalog_item_id: catalog_item.id, dose: "50", dose_unit: "mg", route: "oral", frequency: { kind: "interval", interval_hours: 8 } }.merge(over)
  end

  def issue!(items = [ item ])
    result = Urgency::IssuePrescription.call(encounter: encounter, items: items.map(&:deep_stringify_keys), by: doctor,
                                             catalog: { losartana.id => losartana, diazepam.id => diazepam })
    raise "issue! recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:prescription)
  end

  def other_encounter_item!
    other = in_care_encounter!(upa).tap { |e| urgency_consultation!(e, doctor: doctor) }
    result = Urgency::IssuePrescription.call(encounter: other, items: [ item.deep_stringify_keys ], by: doctor,
                                             catalog: { losartana.id => losartana })
    raise "recusado: #{result.reason}" if result.failure?

    result.payload.fetch(:prescription).items.first
  end

  def administer(row, **body)
    json_post("/urgency/administrations", { prescription_item_id: row.id, scheduled_at: row.first_dose_at.iso8601, status: "administered" }.merge(body))
  end

  def expect_refusal(status, error, path)
    expect(response).to have_http_status(status)
    expect(json_body).to include("error" => error, "path" => path)
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

  it "o interruptor utilizável: baixa 1 do lote FEFO, a resposta traz o lote e a quantidade e shortfall null" do
    expect(Urgency::StockGate.usable?(city)).to be(true)
    lot = lot!(location, item: losartana, quantity: "10", lot_number: "FEFO-1", expires_on: today + 30)
    lot!(location, item: losartana, quantity: "10", lot_number: "FEFO-0", expires_on: today + 90)
    row = issue!.items.first
    expect { administer(row) }.to change(StockMovement, :count).by(1).and(not_change(UrgencyStockShortfall, :count))
    expect(response).to have_http_status(:created)
    expect(json_body["shortfall"]).to be_nil
    adm = json_body["administration"]
    expect(adm).to include("stock_lot" => { "id" => lot.id, "lot_number" => "FEFO-1", "expires_on" => (today + 30).iso8601 },
                           "stock_quantity" => "1.00")
    movement = StockMovement.find_by!(urgency_administration_id: adm["id"])
    expect(movement).to have_attributes(kind: "administration", stock_location_id: location.id, stock_lot_id: lot.id, quantity: -1)
    expect(balance_of(location, lot)).to eq(9)
    expect(shortfall_events).to be_empty
  end

  it "o lote do corpo com stock_quantity em texto decimal → baixa daquele lote, saída com duas casas" do
    lot!(location, item: losartana, quantity: "10", expires_on: today + 10)
    chosen = lot!(location, item: losartana, quantity: "10", expires_on: today + 200)
    row = issue!.items.first
    administer(row, stock_lot_id: chosen.id.upcase, stock_quantity: "2.5")
    expect(response).to have_http_status(:created)
    expect(json_body["administration"]).to include("stock_quantity" => "2.50")
    expect(json_body.dig("administration", "stock_lot", "id")).to eq(chosen.id)
    expect(balance_of(location, chosen)).to eq(BigDecimal("7.5"))
  end

  it "controlado (diazepam B1) com o interruptor utilizável gera o movimento administration (P1)" do
    lot = lot!(location, item: diazepam, quantity: "20")
    row = issue!([ item(diazepam, dose: "5") ]).items.first
    expect(row.controlled_list).to be_present
    administer(row)
    expect(response).to have_http_status(:created)
    expect(StockMovement.find_by!(urgency_administration_id: json_body.dig("administration", "id")))
      .to have_attributes(kind: "administration", stock_lot_id: lot.id, quantity: -1)
    expect(balance_of(location, lot)).to eq(19)
  end

  it "lote de outra unidade de dispensação: o FEFO o ignora (insufficient_balance); no corpo → 422 lot_invalid sem gravar nada" do
    StockLot.create!(catalog_item_id: losartana.id, catmat_code: losartana.catmat_code, lot_number: "FRASCO-1", expires_on: today + 60,
                     dispensing_unit: "frasco", created_by_user: pharmacy_admin!)
    other = lot!(location, item: losartana, quantity: "9", lot_number: "FRASCO-1", expires_on: today + 60)
    row = issue!.items.first

    expect { administer(row, stock_lot_id: other.id) }
      .to not_change(UrgencyAdministration, :count).and(not_change(StockMovement, :count)).and(not_change(UrgencyStockShortfall, :count))
    expect_refusal(:unprocessable_entity, "lot_invalid", "stock_lot_id")

    administer(row)
    expect(response).to have_http_status(:created)
    expect(json_body["shortfall"]).to eq("cause" => "insufficient_balance")
    expect(json_body.dig("administration", "stock_lot")).to be_nil
    expect(balance_of(location, other)).to eq(9)
  end

  it "lote com bloqueio aberto no local: o FEFO o ignora; no corpo → 422 lot_invalid" do
    blocked = lot!(location, item: losartana, quantity: "9", expires_on: today + 5)
    free = lot!(location, item: losartana, quantity: "9", expires_on: today + 50)
    lot_block!(location, blocked)
    row = issue!.items.first

    expect { administer(row, stock_lot_id: blocked.id) }.not_to change(UrgencyAdministration, :count)
    expect_refusal(:unprocessable_entity, "lot_invalid", "stock_lot_id")

    administer(row)
    expect(response).to have_http_status(:created)
    expect(json_body.dig("administration", "stock_lot", "id")).to eq(free.id)
    expect(balance_of(location, blocked)).to eq(9)
  end

  it "sem local unit ativo na UPA → 201 com shortfall no_location; o evento leva só o shortfall_id" do
    location.update!(active: false)
    row = issue!.items.first
    expect { administer(row) }.to change(UrgencyStockShortfall, :count).by(1).and(not_change(StockMovement, :count))
    expect(response).to have_http_status(:created)
    expect(json_body["shortfall"]).to eq("cause" => "no_location")
    shortfall = UrgencyStockShortfall.sole
    expect(shortfall).to have_attributes(urgency_administration_id: json_body.dig("administration", "id"), stock_location_id: nil,
                                         catalog_item_id: losartana.id, quantity: 1, cause: "no_location", reconciled_at: nil)
    expect(shortfall_events.sole.payload).to eq("shortfall_id" => shortfall.id)
    expect(DomainEvent.where(name: "urgency.medication_checked").sole.payload)
      .to eq("encounter_id" => encounter.id, "administration_id" => json_body.dig("administration", "id"))
  end

  it "o lote do corpo com saldo menor que a quantidade → 201 com shortfall lot_unavailable, sem movimento" do
    lot = lot!(location, item: losartana, quantity: "1")
    row = issue!.items.first
    expect { administer(row, stock_lot_id: lot.id, stock_quantity: "2") }.not_to change(StockMovement, :count)
    expect(response).to have_http_status(:created)
    expect(json_body["shortfall"]).to eq("cause" => "lot_unavailable")
    expect(UrgencyStockShortfall.sole).to have_attributes(stock_location_id: location.id, quantity: 2)
  end

  it "o lote do corpo já consumido por outra checagem → 201 com o próximo lote do FEFO (§12 Q12); sem outro → shortfall lot_unavailable" do
    chosen = lot!(location, item: losartana, quantity: "1", expires_on: today + 5)
    next_lot = lot!(location, item: losartana, quantity: "1", expires_on: today + 30)
    # Três encontros (o mesmo medicamento no mesmo horário do mesmo encontro seria slot_taken).
    administer(issue!.items.first, stock_lot_id: chosen.id)
    expect(json_body.dig("administration", "stock_lot", "id")).to eq(chosen.id)

    administer(other_encounter_item!, stock_lot_id: chosen.id)
    expect(response).to have_http_status(:created)
    expect(json_body.dig("administration", "stock_lot", "id")).to eq(next_lot.id)
    expect(json_body["shortfall"]).to be_nil

    administer(other_encounter_item!, stock_lot_id: chosen.id)
    expect(response).to have_http_status(:created)
    expect(json_body.dig("administration", "stock_lot")).to be_nil
    expect(json_body["shortfall"]).to eq("cause" => "lot_unavailable")
    expect([ balance_of(location, chosen), balance_of(location, next_lot) ]).to eq([ 0, 0 ])
  end

  it "stock_quantity como número JSON → 422 invalid_request; stock_lot_id malformado → 422 invalid_request" do
    lot!(location, item: losartana, quantity: "5")
    row = issue!.items.first
    expect { administer(row, stock_quantity: 1) }.not_to change(UrgencyAdministration, :count)
    expect_refusal(:unprocessable_entity, "invalid_request", "stock_quantity")
    administer(row, stock_lot_id: "lote-1")
    expect_refusal(:unprocessable_entity, "invalid_request", "stock_lot_id")
  end

  it "recusada com o interruptor utilizável: sem movimento nem falta" do
    lot!(location, item: losartana, quantity: "5")
    row = issue!.items.first
    expect { administer(row, status: "refused", reason: "Paciente recusou a medicação") }
      .to not_change(StockMovement, :count).and(not_change(UrgencyStockShortfall, :count))
    expect(response).to have_http_status(:created)
    expect(json_body["shortfall"]).to be_nil
  end
end
