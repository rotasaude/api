require "rails_helper"

# Módulo 29, Task 6 (ADR 0047; Desvios 3–7; §15 V4, V18, V19; formas D5/D6 do
# dashboard): o razão do 27a carrega imunobiológico. Vacina entra só na rede de
# frio (cold_chain_central) e na sala (vaccine_room), pelas rotas do 27a, com o
# portão `vaccination`; medicamento nunca entra nesses locais. A entrada leva
# `immunobiological_code`, `manufacturer_key` (da lista do produto) e `package`
# (doses por frasco × frascos); o lote não grava código de fabricante.
RSpec.describe "Estoque de imunobiológicos pelas rotas do 27a", type: :request do
  let!(:city) { vaccination_city! } # pharmacy DESLIGADO
  let!(:central) { cold_chain_central! }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:room) { vaccine_room! }
  let(:today) { Time.zone.today }
  let(:loss_reason) { "Frasco caiu no chão da sala" }

  def line(**over)
    { immunobiological_code: "42", manufacturer_key: "serum", lot_number: "PEN001", expires_on: (today + 200).iso8601,
      quantity: "100", package: { units_per_package: 1, packages: 100 } }.merge(over)
  end

  def receipt(items = [ line ], location: central)
    json_post "/pharmacy/receipts", location_id: location.id, document: { kind: "invoice", number: "GUIA-77", supplier: "Regional de Saúde" },
                                    items: items
  end

  def room_lead! = room_member!(room, role: "room_lead", cbo: "223505")
  def problems = json_body["problems"]
  def enable!(key, on = true) = Platform::Features.set!(city: city, key: key, enabled: on, maintainer: ledi_maintainer!)

  def penta_item
    { "catalog_item_id" => nil, "catmat_code" => nil, "immunobiological_code" => "42", "item_kind" => "immunobiological",
      "name" => "Vacina penta (DTP/HB/Hib)", "unit" => "dose", "dispensing_unit" => "dose", "controlled" => false, "controlled_list" => nil }
  end

  describe "entrada, transferência e recebimento" do
    it "entrada na central em doses, transferência para a sala, recebimento pela técnica" do
      sign_in_as(keeper)
      receipt
      expect(response).to have_http_status(:created)
      lot = StockLot.sole
      expect(lot).to have_attributes(item_kind: "immunobiological", immunobiological_code: "42", catalog_item_id: nil, catmat_code: nil,
                                     dispensing_unit: "dose", manufacturer_key: "serum", manufacturer: "Serum Institute of India")
      expect(json_body["items"]).to eq([ { "lot" => { "id" => lot.id, "item" => penta_item, "lot_number" => "PEN001",
                                                      "expires_on" => (today + 200).iso8601, "manufacturer" => "Serum Institute of India",
                                                      "manufacturer_key" => "serum" },
                                           "quantity" => "100.00" } ])
      movement = StockMovement.sole
      expect(movement).to have_attributes(immunobiological_code: "42", catalog_item_id: nil, package_units: 1, packages: 100)

      json_post "/pharmacy/transfers", from_location_id: central.id, to_location_id: room.stock_location_id, items: [ { lot_id: lot.id, quantity: "20" } ]
      expect(response).to have_http_status(:created)
      expect(json_body["from"]["kind"]).to eq("cold_chain_central")
      expect(balance_of(central, lot)).to eq(80)

      sign_in_as(room_member!(room, role: "vaccinator"))
      json_post "/pharmacy/transfers/#{StockTransfer.sole.id}/receive", items: [ { lot_id: lot.id, quantity_received: "20" } ]
      expect(response).to have_http_status(:ok)
      expect(balance_of(room.stock_location, lot)).to eq(20)
    end

    it "multidose: package com as doses do frasco do catálogo; outro tamanho de frasco → items[i].package" do
      sign_in_as(keeper)
      receipt([ line(immunobiological_code: "22", manufacturer_key: "sanofi", quantity: "50", package: { units_per_package: 10, packages: 5 }),
                line(immunobiological_code: "22", manufacturer_key: "sanofi", lot_number: "VIP2", quantity: nil,
                     package: { units_per_package: 20, packages: 5 }) ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(problems).to eq([ { "path" => "items[1].package", "error" => "invalid_quantity" } ])
      expect(StockLot.count).to eq(0)
    end

    it "sem package, código desconhecido e fabricante fora da lista do produto: todas as recusas de uma vez" do
      sign_in_as(keeper)
      receipt([ line(package: nil), line(lot_number: "X2", immunobiological_code: "999999"), line(lot_number: "X3", manufacturer_key: "fiocruz"),
                line(lot_number: "X4", manufacturer_key: nil) ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(problems).to eq([ { "path" => "items[0].package", "error" => "invalid_quantity" },
                               { "path" => "items[1].immunobiological_code", "error" => "immunobiological_unknown" },
                               { "path" => "items[2].manufacturer_key", "error" => "manufacturer_not_in_catalog" },
                               { "path" => "items[3].manufacturer_key", "error" => "manufacturer_not_in_catalog" } ])
    end

    it "o mesmo lote com outro fabricante → lot_mismatch" do
      vaccine_lot!(central, code: "15", lot_number: "BCG1", manufacturer_key: "serum", expires_on: today + 200)
      sign_in_as(keeper)
      receipt([ line(immunobiological_code: "15", manufacturer_key: "fiocruz", lot_number: "BCG1", quantity: "10",
                     package: { units_per_package: 10, packages: 1 }) ])
      expect(problems).to eq([ { "path" => "items[0].lot_number", "error" => "lot_mismatch" } ])
    end

    it "medicamento na central de frio → item_not_allowed_here; vacina na farmácia da unidade → idem" do
      sign_in_as(keeper)
      receipt([ { catalog_item_id: SecureRandom.uuid, lot_number: "X", expires_on: "2027-01-01", quantity: "1" } ])
      expect(problems).to include("path" => "items[0]", "error" => "item_not_allowed_here")

      pharmacy_city!
      farmacia = unit_location!
      sign_in_as(pharmacy_staff!(farmacia, "stock_keeper"))
      receipt([ line ], location: farmacia)
      expect(problems).to include("path" => "items[0]", "error" => "item_not_allowed_here")
      expect(StockLot.count).to eq(0)
    end

    it "inventário inicial da sala pelo responsável (uma vez por imunobiológico); a técnica não" do
      sign_in_as(room_member!(room, role: "vaccinator"))
      json_post "/pharmacy/openings", location_id: room.stock_location_id, items: [ line(quantity: "12", package: { units_per_package: 1, packages: 12 }) ]
      expect(response).to have_http_status(:forbidden)

      stepped_up!(room_lead!)
      json_post "/pharmacy/openings", location_id: room.stock_location_id, items: [ line(quantity: "12", package: { units_per_package: 1, packages: 12 }) ]
      expect(response).to have_http_status(:created)
      expect(StockOpening.sole).to have_attributes(immunobiological_code: "42", catalog_item_id: nil)
      json_post "/pharmacy/openings", location_id: room.stock_location_id,
                                      items: [ line(lot_number: "PEN002", quantity: "1", package: { units_per_package: 1, packages: 1 }) ]
      expect(response).to have_http_status(:conflict)
      expect(problems).to eq([ { "path" => "items[0].immunobiological_code", "error" => "opening_exists" } ])
    end

    it "transferência sem from_location_id parte do central de medicamentos (o almoxarife da rede de frio não é dele → 403)" do
      lot = vaccine_lot!(central, doses: 30)
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", to_location_id: room.stock_location_id, items: [ { lot_id: lot.id, quantity: "5" } ]
      expect(response).to have_http_status(:forbidden)
    end

    it "da rede de frio só para sala de vacina; lote de medicamento não sai da rede de frio" do
      pharmacy_city!
      farmacia = unit_location!
      lot = vaccine_lot!(central, doses: 30)
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", from_location_id: central.id, to_location_id: farmacia.id, items: [ { lot_id: lot.id, quantity: "5" } ]
      expect(problems).to eq([ { "path" => "to_location_id", "error" => "invalid_request" } ])

      med = stocked_lot!(central_location!, item: losartana)
      json_post "/pharmacy/transfers", from_location_id: central.id, to_location_id: room.stock_location_id, items: [ { lot_id: med.id, quantity: "5" } ]
      expect(problems).to include("path" => "items[0]", "error" => "item_not_allowed_here")
    end

    it "lote bloqueado (excursão aberta) na origem não é transferido" do
      lot = vaccine_lot!(central, doses: 30)
      lot_block!(central, lot)
      sign_in_as(keeper)
      json_post "/pharmacy/transfers", from_location_id: central.id, to_location_id: room.stock_location_id, items: [ { lot_id: lot.id, quantity: "5" } ]
      expect(problems).to eq([ { "path" => "items[0].lot_id", "error" => "lot_blocked" } ])
      expect(StockTransfer.count).to eq(0)
    end
  end

  describe "portões" do
    it "rotas de farmácia seguem 403 com pharmacy desligado" do
      sign_in_as(keeper)
      json_post "/pharmacy/dispensations", {}
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "pharmacy")
      get "/pharmacy/locations"
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "pharmacy")
    end

    it "local de vacina com vaccination desligado → 403 vaccination; local de medicamento com pharmacy desligado → 403 pharmacy" do
      pharmacy_city!
      enable!("vaccination", false)
      sign_in_as(keeper)
      receipt
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "vaccination")

      enable!("vaccination")
      enable!("pharmacy", false)
      farmacia_keeper = pharmacy_staff!(central_location!, "stock_keeper")
      sign_in_as(farmacia_keeper)
      json_post "/pharmacy/receipts", location_id: central_location!.id, document: { kind: "invoice", number: "N1", supplier: "S" },
                                      items: [ { catalog_item_id: losartana.id, lot_number: "X", expires_on: "2030-01-01", quantity: "1" } ]
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "pharmacy")
    end

    it "nenhum dos dois ligado → 403 pharmacy" do
      enable!("vaccination", false)
      sign_in_as(keeper)
      receipt
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "pharmacy")
    end
  end

  describe "posição e extrato" do
    it "posição da sala: item de vacina, blocked por lote, minimum null; sem trilha" do
      lot = vaccine_lot!(room, doses: 10, manufacturer_key: "serum")
      other = vaccine_lot!(room, code: "22", doses: 20)
      lot_block!(room.stock_location, other)
      sign_in_as(room_member!(room, role: "vaccinator"))
      get "/pharmacy/positions", params: { location_id: room.stock_location_id }
      expect(response).to have_http_status(:ok)
      positions = json_body["positions"]
      expect(positions.map { |p| p["item"]["immunobiological_code"] }).to contain_exactly("42", "22")
      penta = positions.find { |p| p["item"]["immunobiological_code"] == "42" }
      expect(penta).to include("item" => penta_item, "balance" => "10.00", "minimum" => nil, "below_minimum" => false, "expiring_soon" => false)
      expect(penta["lots"]).to eq([ { "lot" => { "id" => lot.id, "item" => penta_item, "lot_number" => lot.lot_number, "expires_on" => lot.expires_on.iso8601,
                                                 "manufacturer" => "Serum Institute of India", "manufacturer_key" => "serum" },
                                      "balance" => "10.00", "in_transit" => "0.00", "expiring_soon" => false, "expired" => false, "blocked" => false } ])
      vip = positions.find { |p| p["item"]["immunobiological_code"] == "22" }
      expect(vip["lots"].sole["blocked"]).to be(true)
      expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty
    end

    it "sem location_id: os locais de vacina da pessoa; com locais dos dois domínios → 422 location_id" do
      vaccine_lot!(central, doses: 10)
      sign_in_as(keeper)
      get "/pharmacy/positions"
      expect(response).to have_http_status(:ok)
      expect(json_body["positions"].map { |p| p["location"]["id"] }).to eq([ central.id ])

      pharmacy_city!
      Membership.create!(user: keeper, role: "stock_keeper", granted_at: Time.current) unless keeper.has_role?("stock_keeper")
      StockLocationStaff.create!(stock_location: central_location!, user: keeper, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      get "/pharmacy/positions"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["path"]).to eq("location_id")
    end

    it "o almoxarife da rede de frio lê a posição da sala; a técnica de outra sala não" do
      vaccine_lot!(room, doses: 4)
      sign_in_as(keeper)
      get "/pharmacy/positions", params: { location_id: room.stock_location_id }
      expect(response).to have_http_status(:ok)
      sign_in_as(room_member!(vaccine_room!))
      get "/pharmacy/positions", params: { location_id: room.stock_location_id }
      expect(response).to have_http_status(:forbidden)
    end

    it "extrato do lote de vacina na sala" do
      lot = vaccine_lot!(room, doses: 7)
      sign_in_as(room_member!(room))
      get "/pharmacy/lots/#{lot.id}/movements", params: { location_id: room.stock_location_id }
      expect(response).to have_http_status(:ok)
      expect(json_body["lot"]["item"]).to eq(penta_item)
      expect(json_body["balance"]).to eq("7.00")
      expect(json_body["movements"].sole).to include("kind" => "receipt", "quantity" => "7.00")
    end
  end

  describe "perdas e ajustes" do
    it "perda física de vacina exige loss_code da lista; só o room_lead" do
      lot = vaccine_lot!(room, doses: 10)
      stepped_up!(room_member!(room, role: "vaccinator"))
      json_post "/pharmacy/adjustments", location_id: room.stock_location_id, lot_id: lot.id, kind: "loss", quantity: "1", reason: loss_reason
      expect(response).to have_http_status(:forbidden)

      stepped_up!(room_lead!)
      json_post "/pharmacy/adjustments", location_id: room.stock_location_id, lot_id: lot.id, kind: "loss", quantity: "1", reason: loss_reason
      expect(problems).to include("path" => "loss_code", "error" => "required")
      json_post "/pharmacy/adjustments", location_id: room.stock_location_id, lot_id: lot.id, kind: "loss", quantity: "1", reason: loss_reason,
                                         loss_code: "lost_in_space"
      expect(problems).to include("path" => "loss_code", "error" => "invalid_request")

      json_post "/pharmacy/adjustments", location_id: room.stock_location_id, lot_id: lot.id, kind: "loss", quantity: "1", reason: loss_reason,
                                         loss_code: "broken"
      expect(response).to have_http_status(:created)
      expect(json_body).to include("kind" => "loss", "loss_code" => "broken", "quantity" => "-1.00")
      expect(json_body["lot"]["item"]).to eq(penta_item)
      expect(StockAdjustment.sole.loss_code).to eq("broken")
      expect(balance_of(room.stock_location, lot)).to eq(9)
    end

    it "contagem de vacina não pede loss_code; lote bloqueado no local → lot_blocked" do
      lot = vaccine_lot!(room, doses: 10)
      stepped_up!(room_lead!)
      json_post "/pharmacy/adjustments", location_id: room.stock_location_id, lot_id: lot.id, kind: "adjustment", counted_quantity: "10",
                                         reason: "Contagem semanal da geladeira"
      expect(problems).to eq([ { "path" => "counted_quantity", "error" => "no_difference" } ])

      lot_block!(room.stock_location, lot)
      json_post "/pharmacy/adjustments", location_id: room.stock_location_id, lot_id: lot.id, kind: "loss", quantity: "1", reason: loss_reason,
                                         loss_code: "broken"
      expect(problems).to eq([ { "path" => "lot_id", "error" => "lot_blocked" } ])
      expect(StockAdjustment.count).to eq(0)
    end

    it "lote de vacina em local de medicamento → item_not_allowed_here" do
      pharmacy_city!
      farmacia = unit_location!
      lot = vaccine_lot!(room, doses: 10)
      stepped_up!(pharmacy_staff!(farmacia, "stock_keeper"))
      json_post "/pharmacy/adjustments", location_id: farmacia.id, lot_id: lot.id, kind: "loss", quantity: "1", reason: loss_reason
      expect(problems).to include("path" => "lot_id", "error" => "item_not_allowed_here")
    end
  end
end
