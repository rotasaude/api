require "rails_helper"

# Módulo 29, Task 7 (ADR 0047, Desvios 7 e 8; contrato §3; §15 V14; D7 do
# dashboard): abrir, listar e descartar frascos multidose. Nenhuma regra de
# abertura além de lote da sala, válido, não bloqueado e com saldo (NT 236/2026).
RSpec.describe "Sala de vacina — frascos multidose", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:base) { "/vaccination/rooms/#{room.id}/vials" }

  def post_json(path, body) = post(path, params: body.to_json, headers: json_headers)
  def balance(lot) = balance_of(room.stock_location, lot)
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def cancel!(dose) = dose.update!(cancelled_at: Time.current, cancelled_by_user: lead, cancel_reason: "registro duplicado")
  def events(name) = DomainEvent.where(name: name).order(:created_at, :id).map(&:payload)

  describe "POST /vaccination/rooms/:room_id/vials" do
    before { sign_in_as(vaccinator) }

    it "abre frasco: saem doses_per_vial do lote, vence pelo fabricante" do
      lot = vaccine_lot!(room, code: "22", doses: 20, manufacturer_key: "sanofi") # VIP, 10 doses, 672 h
      opened = Time.zone.parse("2026-11-03 08:00")
      travel_to(opened) { post_json(base, lot_id: lot.id) }
      expect(response).to have_http_status(:created)
      expect(json_body).to include("doses_per_vial" => 10, "doses_used" => 0, "doses_left" => 10, "status" => "open",
                                   "lot" => { "id" => lot.id, "number" => lot.lot_number, "immunobiological_code" => "22" })
      expect(json_body.keys).to eq(%w[id lot opened_at expires_at doses_per_vial doses_used doses_left status])
      expect(Time.iso8601(json_body["opened_at"])).to eq(opened)
      expect(Time.iso8601(json_body["expires_at"])).to eq(opened + 672.hours)
      expect(balance(lot)).to eq(10)
      movement = StockMovement.where(kind: "vial_opening").sole
      expect(movement).to have_attributes(quantity: -10, vial_opening_id: json_body["id"], stock_location_id: room.stock_location_id)
      expect(events("vaccination.vial_opened")).to eq([ { "vial_opening_id" => json_body["id"], "vaccine_room_id" => room.id, "user_id" => vaccinator.id } ])
    end

    it "validade pelo fabricante escolhido pela chave do lote; sem chave, a menor do produto" do
      by_key = vaccine_lot!(room, code: "15", doses: 10, manufacturer_key: "fiocruz") # 8 h
      post_json(base, lot_id: by_key.id)
      expect(Time.iso8601(json_body["expires_at"]) - Time.iso8601(json_body["opened_at"])).to eq(8.hours)
      without_key = vaccine_lot!(room, code: "15", doses: 10) # menor: 6 h
      post_json(base, lot_id: without_key.id)
      expect(Time.iso8601(json_body["expires_at"]) - Time.iso8601(json_body["opened_at"])).to eq(6.hours)
    end

    it "unidose não abre frasco" do
      lot = vaccine_lot!(room, code: "42")
      post_json(base, lot_id: lot.id)
      expect([ response.status, json_body ]).to eq([ 422, refusal("not_multidose", "lot_id") ])
      expect(balance(lot)).to eq(10)
    end

    it "lote de outra sala, lote inexistente e lote de medicamento → 404 lot_not_in_room" do
      other = vaccine_lot!(vaccine_room!, code: "22")
      post_json(base, lot_id: other.id)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "lot_not_in_room" } ])
      post_json(base, lot_id: SecureRandom.uuid)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "lot_not_in_room" } ])
      expect(VialOpening.count).to eq(0)
    end

    it "lot_id ausente ou malformado → 422 lot_id" do
      post_json(base, {})
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "lot_id") ])
      post_json(base, lot_id: "x")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "lote vencido → lot_expired; o dia da validade ainda vale" do
      expired = vaccine_lot!(room, code: "22", expires_on: Time.zone.today - 1)
      post_json(base, lot_id: expired.id)
      expect([ response.status, json_body ]).to eq([ 422, refusal("lot_expired", "lot_id") ])
      today = vaccine_lot!(room, code: "22", expires_on: Time.zone.today)
      post_json(base, lot_id: today.id)
      expect(response).to have_http_status(:created)
    end

    it "lote bloqueado por excursão → lot_blocked, sem movimento; liberado, abre" do
      lot = vaccine_lot!(room, code: "22")
      block = lot_block!(room.stock_location, lot)
      post_json(base, lot_id: lot.id)
      expect([ response.status, json_body ]).to eq([ 422, refusal("lot_blocked", "lot_id") ])
      expect(balance(lot)).to eq(10)
      block.update_columns(released_at: Time.current, decision: "use")
      post_json(base, lot_id: lot.id)
      expect(response).to have_http_status(:created)
    end

    it "saldo menor que as doses do frasco → insufficient_balance" do
      lot = vaccine_lot!(room, code: "22", doses: 9)
      post_json(base, lot_id: lot.id)
      expect([ response.status, json_body ]).to eq([ 422, refusal("insufficient_balance", "lot_id") ])
      expect(VialOpening.count).to eq(0)
    end

    it "não exige agendamento nem número de pessoas: lote válido, não bloqueado e com saldo basta; dois frascos do mesmo lote" do
      lot = vaccine_lot!(room, code: "22", doses: 20)
      2.times { post_json(base, lot_id: lot.id) }
      expect(VialOpening.count).to eq(2)
      expect(balance(lot)).to eq(0)
      post_json(base, lot_id: lot.id)
      expect(json_body["error"]).to eq("insufficient_balance")
    end

    it "lote na query → 422; sem papel na sala → 403; sala inativa → 403; sala inexistente → 404" do
      lot = vaccine_lot!(room, code: "22")
      post "#{base}?lot_id=#{lot.id}", headers: json_headers
      expect(response).to have_http_status(:unprocessable_entity)
      sign_in_as(room_member!(vaccine_room!))
      post_json(base, lot_id: lot.id)
      expect(response).to have_http_status(:forbidden)
      sign_in_as(vaccinator)
      room.update!(active: false)
      post_json(base, lot_id: lot.id)
      expect(response).to have_http_status(:forbidden)
      post_json("/vaccination/rooms/#{SecureRandom.uuid}/vials", lot_id: lot.id)
      expect(response).to have_http_status(:not_found)
    end

    it "vacina desligada → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      post_json(base, lot_id: SecureRandom.uuid)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end

    it "o responsável da sala também abre" do
      sign_in_as(lead)
      post_json(base, lot_id: vaccine_lot!(room, code: "22").id)
      expect(response).to have_http_status(:created)
    end
  end

  describe "GET /vaccination/rooms/:room_id/vials" do
    before { sign_in_as(vaccinator) }

    it "envelope { vials }, por status, com doses_used das imunizações ativas" do
      open_one = open_vial!(room, lot: vaccine_lot!(room, code: "22"))
      apply_from_vial!(open_one, count: 3)
      cancel!(apply_from_vial!(open_one, count: 1).first)
      past = nil
      travel_to(2.days.ago) { past = open_vial!(room, lot: vaccine_lot!(room, code: "24")) }
      discarded = open_vial!(room, lot: vaccine_lot!(room, code: "22"))
      Vaccination::CloseOutVial.call(vial: discarded, reason: "frasco caiu e trincou", by: lead)
      get base
      expect(json_body.keys).to eq([ "vials" ])
      expect(json_body["vials"].map { |v| v["id"] }).to eq([ discarded.id, open_one.id, past.id ])
      get base, params: { status: "open" }
      expect(json_body["vials"].map { |v| [ v["id"], v["doses_used"], v["doses_left"], v["status"] ] }).to eq([ [ open_one.id, 3, 7, "open" ] ])
      get base, params: { status: "expired" }
      expect(json_body["vials"].map { |v| [ v["id"], v["status"] ] }).to eq([ [ past.id, "expired" ] ])
      get base, params: { status: "closed_out" }
      expect(json_body["vials"].map { |v| [ v["id"], v["status"] ] }).to eq([ [ discarded.id, "closed_out" ] ])
    end

    it "só os frascos da sala; status inválido → 422; outro parâmetro → 422; sem papel → 403" do
      open_vial!(vaccine_room!, lot: vaccine_lot!(vaccine_room!, code: "22")) rescue nil
      get base
      expect(json_body).to eq("vials" => [])
      get base, params: { status: "all" }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "status") ])
      get base, params: { lot_id: "x" }
      expect(response).to have_http_status(:unprocessable_entity)
      sign_in_as(room_member!(vaccine_room!))
      get base
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /vaccination/vials/:id/close_out" do
    let(:vial) { open_vial!(room, lot: vaccine_lot!(room, code: "22")) }

    it "responsável descarta: sobra vira perda técnica, motivo cifrado, evento só com ids" do
      apply_from_vial!(vial, count: 4)
      sign_in_as(lead)
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "  frasco caiu e trincou  ")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => vial.id, "status" => "closed_out", "doses_used" => 4, "doses_left" => 6)
      expect(vial.reload).to have_attributes(technical_loss_doses: 6, closed_by_user_id: lead.id, close_reason: "frasco caiu e trincou")
      expect(vial.closed_at).to be_present
      raw = VialOpening.connection.select_value("SELECT close_reason FROM vial_openings WHERE id = '#{vial.id}'")
      expect(raw).not_to include("trincou")
      expect(events("vaccination.vial_closed")).to eq([ { "vial_opening_id" => vial.id, "vaccine_room_id" => room.id, "user_id" => lead.id, "cause" => "closed_out" } ])
      expect(DomainEvent.where(name: "vaccination.vial_closed").to_json).not_to include("trincou")
      expect(StockMovement.where(vial_opening_id: vial.id).count).to eq(1) # a perda técnica não move saldo
    end

    it "vacinador sem ser responsável → 403 room_lead_required; sem papel → 403 missing_role" do
      sign_in_as(vaccinator)
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "frasco caiu e trincou")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "room_lead_required" } ])
      sign_in_as(room_member!(vaccine_room!, role: "room_lead", cbo: "223505"))
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "frasco caiu e trincou")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(vial.reload.closed_at).to be_nil
    end

    it "motivo de 10 a 500 caracteres: 9 e 501 recusam, 10 e 500 passam" do
      sign_in_as(lead)
      [ "a" * 9, "a" * 501, nil, 42 ].each do |reason|
        post_json("/vaccination/vials/#{vial.id}/close_out", reason: reason)
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_reason", "reason") ])
      end
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "a" * 10)
      expect(response).to have_http_status(:ok)
      other = open_vial!(room, lot: vaccine_lot!(room, code: "22"))
      post_json("/vaccination/vials/#{other.id}/close_out", reason: "b" * 500)
      expect(response).to have_http_status(:ok)
    end

    it "já fechado (descarte ou vencimento) → 409 already_closed; inexistente ou malformado → 404; motivo na query → 422" do
      sign_in_as(lead)
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "frasco caiu e trincou")
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "frasco caiu e trincou")
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_closed" } ])
      post_json("/vaccination/vials/#{SecureRandom.uuid}/close_out", reason: "frasco caiu e trincou")
      expect(response).to have_http_status(:not_found)
      post_json("/vaccination/vials/x/close_out", reason: "frasco caiu e trincou")
      expect(response).to have_http_status(:not_found)
      post "/vaccination/vials/#{vial.id}/close_out?reason=frasco+caiu+e+trincou", headers: json_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "vínculo do responsável revogado → 403" do
      sign_in_as(lead)
      VaccineRoomStaff.where(user_id: lead.id).update_all(revoked_at: Time.current, revoked_by_user_id: lead.id)
      post_json("/vaccination/vials/#{vial.id}/close_out", reason: "frasco caiu e trincou")
      expect(response).to have_http_status(:forbidden)
    end
  end
end
