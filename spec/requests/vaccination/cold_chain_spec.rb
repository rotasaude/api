require "rails_helper"

# Módulo 29, Task 14 (ADR 0047; contrato §8; §15 V14 = D9 do dashboard;
# Review Focus 4): equipamentos, leituras, a excursão que bloqueia os lotes do
# local e a conduta por lote (use | discard). O descarte passa pelo
# Pharmacy::RequestAdjustment (limite de aprovação do 27a): abaixo do limite
# libera na hora; acima, o lote segue bloqueado até o DecideAdjustment aprovar.
RSpec.describe "Sala de vacina — cadeia de frio", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:other_lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:fridge) { cold_chain_equipment!(room, name: "Geladeira da sala") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61, sex: "female") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:use_reason) { "Termômetro conferido, sem perda" }
  let(:discard_reason) { "Exposição longa acima de 8 graus" }

  def json_post(path, body = {}) = post(path, params: body.to_json, headers: json_headers)
  def json_patch(path, body = {}) = patch(path, params: body.to_json, headers: json_headers)
  def balance(lot) = balance_of(room.stock_location, lot)
  def events(name) = DomainEvent.where(name: name).order(:created_at, :id).map(&:payload)
  def approval_percent!(value) = PharmacySetting.current.update!(adjustment_approval_percent: value)

  def read!(equipment = fridge, current_c: "9.5", min_c: "4.0", max_c: "9.5", read_at: Time.current.iso8601)
    json_post("/vaccination/cold_chain/equipments/#{equipment.id}/readings", read_at: read_at, current_c: current_c, min_c: min_c, max_c: max_c)
  end

  def decide!(excursion_id, lines)
    json_post("/vaccination/cold_chain/excursions/#{excursion_id}/decide", lots: lines)
  end

  def line(lot, decision, reason = (decision == "use" ? use_reason : discard_reason)) = { lot_id: lot.id, decision: decision, reason: reason }

  # Dose pela rota (VIP do frasco, ou penta unidose).
  def dose_via_api(lot:, vial: nil, code: "22")
    json_post("/vaccination/rooms/#{room.id}/immunizations",
              { patient_id: child.id, immunobiological_code: code, dose_code: "1", strategy: "1", care_group: "121", route: "3", site: "18",
                maternal_condition: "1", applied_at: Time.current.iso8601, lot_id: lot.id, vial_id: vial&.id }.compact)
    json_body
  end

  describe "Review Focus 4: geladeira a 9,5 °C no meio do expediente, com frasco aberto" do
    let(:vip) { vaccine_lot!(room, code: "22", doses: 20) }
    let(:penta) { vaccine_lot!(room, code: "42", doses: 5) }
    let!(:vial) { open_vial!(room, lot: vip, by: vaccinator) }

    before { penta }

    it "bloqueia dose nova, frasco novo e o frasco já aberto; a conduta use libera tudo, sem perda" do
      sign_in_as(vaccinator)
      read!
      expect(response).to have_http_status(:created)
      excursion_id = json_body.fetch("excursion_id")
      expect(json_body["blocked_lots"]).to eq(2)
      expect(json_body["reading"]).to include("current_c" => 9.5, "min_c" => 4.0, "max_c" => 9.5, "out_of_range" => true,
                                              "by" => { "name" => vaccinator.professional.professional_name })
      expect(StockLotBlock.open_blocks.where(stock_location_id: room.stock_location_id).pluck(:stock_lot_id)).to contain_exactly(vip.id, penta.id)

      expect(dose_via_api(lot: vip, vial: vial)["problems"]).to include("path" => "lot_id", "error" => "lot_blocked")
      expect(dose_via_api(lot: penta, code: "42")["problems"]).to include("path" => "lot_id", "error" => "lot_blocked")
      json_post("/vaccination/rooms/#{room.id}/vials", lot_id: vip.id)
      expect(json_body["error"]).to eq("lot_blocked")

      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "use"), line(penta, "use") ])
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("excursion_id" => excursion_id, "adjustments" => [])
      expect(ColdChainExcursion.find(excursion_id)).to have_attributes(decided_by_user_id: lead.id)
      expect(StockLotBlock.where(cold_chain_excursion_id: excursion_id).map { |b| [ b.decision, b.decision_reason, b.decided_by_user_id ] })
        .to all(eq([ "use", use_reason, lead.id ]))

      sign_in_as(vaccinator)
      expect(dose_via_api(lot: vip, vial: vial)).to include("status" => "active")
      expect(dose_via_api(lot: penta, code: "42")).to include("status" => "active")
      expect(StockAdjustment.count).to eq(0)
      expect([ balance(vip), balance(penta) ]).to eq([ 10, 4 ])
      expect(events("vaccination.cold_chain_excursion")).to eq([ { "cold_chain_excursion_id" => excursion_id,
                                                                    "stock_location_id" => room.stock_location_id, "user_id" => vaccinator.id } ])
      expect(events("vaccination.cold_chain_excursion_decided").sole).to include("cold_chain_excursion_id" => excursion_id, "user_id" => lead.id)
    end

    it "transferência e ajuste recusam o lote bloqueado" do
      sign_in_as(vaccinator)
      read!
      excursion = ColdChainExcursion.sole
      result = Pharmacy::RequestAdjustment.call(location: room.stock_location, lot: penta, kind: "loss", counted_quantity: nil, quantity: "1",
                                                reason: "Frasco quebrou na bancada", loss_code: "broken", by: lead, settings: Pharmacy::Settings.current)
      expect(result.reason).to eq(:lot_blocked)
      # O contexto de OUTRA excursão não libera.
      other = ColdChainExcursion.create!(cold_chain_reading: ColdChainReading.create!(cold_chain_equipment: fridge, read_at: Time.current, current_c: 9,
                                                                                       min_c: 9, max_c: 9, recorded_by_user: lead),
                                         stock_location: room.stock_location)
      result = Pharmacy::RequestAdjustment.call(location: room.stock_location, lot: penta, kind: "loss", counted_quantity: nil, quantity: "5",
                                                reason: discard_reason, loss_code: "temperature_excursion", by: lead,
                                                settings: Pharmacy::Settings.current, excursion: other)
      expect(result.reason).to eq(:lot_blocked)
      expect(excursion.reload.decided_at).to be_nil
    end
  end

  describe "conduta discard" do
    let(:vip) { vaccine_lot!(room, code: "22", doses: 20) }
    let!(:vial) { open_vial!(room, lot: vip, by: vaccinator) }
    let(:excursion_id) do
      sign_in_as(vaccinator)
      read!
      json_body.fetch("excursion_id")
    end

    it "abaixo do limite: perda física de todo o saldo, aplicada; fecha o frasco do lote e libera" do
      approval_percent!(100)
      excursion_id
      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "discard") ])
      expect(response).to have_http_status(:ok)
      adjustment = StockAdjustment.sole
      expect(adjustment).to have_attributes(kind: "loss", status: "applied", loss_code: "temperature_excursion", quantity: -10, reason: discard_reason)
      expect(json_body["excursion_id"]).to eq(excursion_id)
      expect(json_body["adjustments"].sole).to include("id" => adjustment.id, "kind" => "loss", "status" => "applied", "quantity" => "-10.00",
                                                       "loss_code" => "temperature_excursion")
      expect(balance(vip)).to eq(0)
      expect(vial.reload).to have_attributes(technical_loss_doses: 10, closed_by_user_id: lead.id, close_reason: discard_reason)
      expect(vial.status).to eq("closed_out")
      expect(StockLotBlock.sole).to have_attributes(decision: "discard", stock_adjustment_id: adjustment.id)
      expect(ColdChainExcursion.find(excursion_id).decided_at).to be_present
    end

    it "acima do limite: pendente → segue bloqueado → aprovado → desbloqueado com a perda" do
      approval_percent!(10)
      excursion_id
      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "discard") ])
      expect(response).to have_http_status(:ok)
      adjustment = StockAdjustment.sole
      expect(adjustment).to have_attributes(kind: "loss", status: "pending", quantity: -10, loss_code: "temperature_excursion")
      expect(json_body["adjustments"].sole).to include("id" => adjustment.id, "status" => "pending")
      expect(balance(vip)).to eq(10)
      expect(StockLotBlock.sole).to have_attributes(released_at: nil, stock_adjustment_id: adjustment.id)
      expect(ColdChainExcursion.find(excursion_id).decided_at).to be_nil

      # Pendente: o lote continua bloqueado para dose (frasco aberto) e para abrir frasco.
      sign_in_as(vaccinator)
      expect(dose_via_api(lot: vip, vial: vial)["problems"]).to include("path" => "lot_id", "error" => "lot_blocked")
      json_post("/vaccination/rooms/#{room.id}/vials", lot_id: vip.id)
      expect(json_body["error"]).to eq("lot_blocked")
      # A conduta não se repete sobre o lote pendente.
      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "use") ])
      expect([ response.status, json_body["error"] ]).to eq([ 422, "adjustment_pending" ])
      expect(json_body["problems"]).to eq([ { "path" => "lots[0].lot_id", "error" => "adjustment_pending" } ])
      # Status mostra a excursão aberta com o ajuste pendente.
      get "/vaccination/cold_chain/status", params: { location_id: room.stock_location_id }
      expect(json_body["open_excursions"].sole["lots"].sole).to include("lot_id" => vip.id, "pending_adjustment_id" => adjustment.id)

      # Quem pediu não aprova; outro responsável aprova (step-up).
      stepped_up!(other_lead)
      json_post("/pharmacy/adjustments/#{adjustment.id}/approve", {})
      expect(response).to have_http_status(:ok)
      expect(adjustment.reload).to have_attributes(status: "approved", decided_by_user_id: other_lead.id)
      expect(StockMovement.where(stock_adjustment_id: adjustment.id).sole).to have_attributes(kind: "loss", quantity: -10)
      expect(balance(vip)).to eq(0)
      expect(StockLotBlock.sole).to have_attributes(decision: "discard", decided_by_user_id: lead.id)
      expect(StockLotBlock.sole.released_at).to be_present
      expect(vial.reload).to have_attributes(technical_loss_doses: 10, closed_by_user_id: lead.id)
      expect(ColdChainExcursion.find(excursion_id)).to have_attributes(decided_by_user_id: lead.id)
      expect(ColdChainExcursion.find(excursion_id).decided_at).to be_present
    end

    it "acima do limite e recusado: o lote segue bloqueado e a conduta pode ser refeita" do
      approval_percent!(10)
      excursion_id
      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "discard") ])
      adjustment = StockAdjustment.sole
      stepped_up!(other_lead)
      json_post("/pharmacy/adjustments/#{adjustment.id}/reject", reason: "Termômetro estava descalibrado")
      expect(response).to have_http_status(:ok)
      expect(StockLotBlock.sole.released_at).to be_nil
      expect(vial.reload.closed_at).to be_nil
      expect(balance(vip)).to eq(10)

      decide!(excursion_id, [ line(vip, "use") ])
      expect(response).to have_http_status(:ok)
      expect(StockLotBlock.sole).to have_attributes(decision: "use", decided_by_user_id: other_lead.id, stock_adjustment_id: nil)
      expect(ColdChainExcursion.find(excursion_id).decided_at).to be_present
    end
  end

  describe "POST /vaccination/cold_chain/excursions/:id/decide — recusas" do
    let(:vip) { vaccine_lot!(room, code: "22", doses: 20) }
    let(:penta) { vaccine_lot!(room, code: "42", doses: 5) }
    let(:excursion_id) do
      vip
      penta
      sign_in_as(vaccinator)
      read!
      json_body.fetch("excursion_id")
    end

    it "sem step-up → 401; vacinador → 403 missing_role" do
      excursion_id
      sign_in_as(lead)
      decide!(excursion_id, [ line(vip, "use"), line(penta, "use") ])
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      stepped_up!(vaccinator)
      decide!(excursion_id, [ line(vip, "use"), line(penta, "use") ])
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end

    it "todos os lotes bloqueados precisam vir (lots_missing); motivo 10–500; decisão válida; nada muda" do
      excursion_id
      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "use") ])
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "lots_missing", "lots" ])
      decide!(excursion_id, [ line(vip, "use", "curto"), { lot_id: penta.id, decision: "keep", reason: use_reason } ])
      expect(json_body["problems"]).to eq([ { "path" => "lots[0].reason", "error" => "invalid_reason" },
                                            { "path" => "lots[1].decision", "error" => "invalid_request" } ])
      decide!(excursion_id, [ line(vip, "use"), line(penta, "use"), line(vaccine_lot!(room, code: "42"), "use") ])
      expect(json_body["problems"]).to eq([ { "path" => "lots[2].lot_id", "error" => "lot_not_in_excursion" } ])
      decide!(excursion_id, [])
      expect(json_body["path"]).to eq("lots")
      expect(StockLotBlock.open_blocks.count).to eq(2)
    end

    it "excursão já decidida → 409 excursion_closed; inexistente → 404" do
      excursion_id
      stepped_up!(lead)
      decide!(excursion_id, [ line(vip, "use"), line(penta, "use") ])
      decide!(excursion_id, [ line(vip, "use"), line(penta, "use") ])
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "excursion_closed" } ])
      decide!(SecureRandom.uuid, [ line(vip, "use") ])
      expect(response).to have_http_status(:not_found)
    end

    it "rede de frio: o stock_keeper decide" do
      central = cold_chain_central!
      keeper = pharmacy_staff!(central, "stock_keeper")
      lot = vaccine_lot!(central, code: "42", doses: 50)
      chamber = cold_chain_equipment!(central, name: "Câmara da rede")
      sign_in_as(keeper)
      read!(chamber, current_c: "1.0", min_c: "1.0", max_c: "5.0")
      expect(json_body["blocked_lots"]).to eq(1)
      stepped_up!(keeper)
      decide!(json_body.fetch("excursion_id"), [ line(lot, "use") ])
      expect(response).to have_http_status(:ok)
    end
  end

  describe "leituras" do
    it "dentro da faixa: 201 sem excursão; recusas de campo e de faixa" do
      vaccine_lot!(room, code: "42")
      sign_in_as(vaccinator)
      read!(current_c: "5", min_c: "3.5", max_c: "7.2")
      expect(response).to have_http_status(:created)
      expect(json_body).to include("excursion_id" => nil, "blocked_lots" => 0)
      expect(json_body["reading"]).to include("current_c" => 5.0, "min_c" => 3.5, "max_c" => 7.2, "out_of_range" => false)
      expect(json_body["reading"].keys).to eq(%w[id read_at current_c min_c max_c out_of_range by])
      expect(StockLotBlock.count).to eq(0)

      read!(current_c: "8.55")
      expect([ response.status, json_body["path"] ]).to eq([ 422, "current_c" ])
      read!(current_c: "5", min_c: "6", max_c: "7")
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_range" ])
      read!(read_at: (Time.current + 1.hour).iso8601, current_c: "5", min_c: "4", max_c: "6")
      expect(json_body["problems"]).to eq([ { "path" => "read_at", "error" => "read_at_in_future" } ])
      expect(ColdChainReading.count).to eq(1)
    end

    it "mínima abaixo da faixa também abre excursão; fora da equipe → 403" do
      vaccine_lot!(room, code: "42")
      sign_in_as(vaccinator)
      read!(current_c: "4.0", min_c: "1.5", max_c: "6.0")
      expect(json_body["excursion_id"]).to be_present
      sign_in_as(room_member!(vaccine_room!))
      read!(current_c: "5", min_c: "4", max_c: "6")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "equipamentos" do
    it "room_lead cria e edita; nome 3–120; faixa válida; vacinador lista mas não cria" do
      stepped_up!(lead)
      json_post("/vaccination/cold_chain/equipments", location_id: room.stock_location_id, name: "Geladeira 2", kind: "refrigerator",
                                                      min_c: 2, max_c: 8, active: true)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("location_id" => room.stock_location_id, "name" => "Geladeira 2", "kind" => "refrigerator",
                                   "min_c" => 2.0, "max_c" => 8.0, "active" => true)
      id = json_body["id"]
      json_patch("/vaccination/cold_chain/equipments/#{id}", name: "Geladeira de vacinas", active: false)
      expect(json_body).to include("name" => "Geladeira de vacinas", "active" => false)
      json_post("/vaccination/cold_chain/equipments", location_id: room.stock_location_id, name: "Ge", kind: "refrigerator", min_c: 2, max_c: 8)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "name" ])
      json_post("/vaccination/cold_chain/equipments", location_id: room.stock_location_id, name: "Freezer", kind: "freezer", min_c: 8, max_c: 2)
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_range" ])

      sign_in_as(vaccinator)
      get "/vaccination/cold_chain/equipments", params: { location_id: room.stock_location_id }
      expect(json_body["equipments"].map { |e| e["id"] }).to eq([ id ])
      json_post("/vaccination/cold_chain/equipments", location_id: room.stock_location_id, name: "Outra", kind: "chamber", min_c: 2, max_c: 8)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  describe "GET /vaccination/cold_chain/status" do
    it "status do dia: leituras do dia e excursões abertas, sem dado pessoal" do
      vip = vaccine_lot!(room, code: "22", doses: 20)
      record!(room, child, lot: vaccine_lot!(room, code: "42"), by: vaccinator)
      sign_in_as(vaccinator)
      travel_to(Time.current.beginning_of_day + 9.hours) do
        read!(read_at: (Time.current - 1.day).iso8601, current_c: "5", min_c: "4", max_c: "6")
        read!
        get "/vaccination/cold_chain/status", params: { location_id: room.stock_location_id }
      end
      expect(response).to have_http_status(:ok)
      equipment = json_body["equipments"].sole
      expect(equipment).to include("id" => fridge.id, "readings_today" => 1, "min_c" => 2.0, "max_c" => 8.0)
      expect(equipment["last_reading"]).to include("current_c" => 9.5, "out_of_range" => true)
      excursion = json_body["open_excursions"].sole
      expect(excursion.keys).to eq(%w[id equipment_id reading lots opened_at])
      expect(excursion["equipment_id"]).to eq(fridge.id)
      vip_line = excursion["lots"].find { |l| l["lot_id"] == vip.id }
      expect(vip_line).to eq("lot_id" => vip.id, "number" => vip.lot_number,
                             "immunobiological" => { "code" => "22", "name" => Vaccination::Immunobiologicals.find("22").name },
                             "balance" => "20.00", "pending_adjustment_id" => nil)
      expect(response.body).not_to include(child.full_name.to_s)
      expect(response.body).not_to include(child.cpf.to_s)
    end
  end
end
