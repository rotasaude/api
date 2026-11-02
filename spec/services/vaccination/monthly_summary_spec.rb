require "rails_helper"

# Módulo 29, Task 15 (ADR 0047; contrato §7; §15 V14 = D8 do dashboard): resumo
# mensal de imunobiológicos por local. Só contagens, em doses; o saldo de
# abertura e o de fechamento batem com os movimentos do razão do 27a.
RSpec.describe "Sala de vacina — resumo mensal", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let!(:central) { cold_chain_central! }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:settings) { Pharmacy::Settings.current }

  def summary(path, month) = get(path, params: { month: month })
  def room_path = "/vaccination/rooms/#{room.id}/monthly_summary"
  def central_path = "/vaccination/cold_chain_central/monthly_summary"
  def row_of(code) = json_body["rows"].find { |entry| entry.dig("immunobiological", "code") == code }
  def refusal(path) = { "error" => "invalid_request", "path" => path, "problems" => [ { "path" => path, "error" => "invalid_request" } ] }

  def send_and_receive!(lot, quantity, to: room.stock_location)
    sent = Pharmacy::SendTransfer.call(from: central, to: to, items: [ { "lot_id" => lot.id, "quantity" => quantity.to_s } ], by: keeper)
    raise sent.inspect if sent.failure?

    got = Pharmacy::ReceiveTransfer.call(transfer: sent.payload[:transfer], items: [ { "lot_id" => lot.id, "quantity_received" => quantity.to_s } ], by: lead)
    raise got.inspect if got.failure?
  end

  def adjust!(lot, **attrs)
    result = Pharmacy::RequestAdjustment.call(**{ location: room.stock_location, lot: lot, kind: "adjustment", counted_quantity: nil, quantity: nil,
                                                  reason: "Contagem do inventário de novembro", by: lead, settings: settings }.merge(attrs))
    raise result.inspect if result.failure?
  end

  # Outubro: rede de frio recebe 100 doses de VIP e manda 10 para a sala.
  # Novembro: manda mais 30; 2 frascos abertos (10 + 3 doses aplicadas, o
  # segundo descartado com 7 sobrando), 1 frasco quebrado (10), contagem +1,
  # contagem +9 aguardando aprovação; unidose recebida (5), 2 doses, 1 cancelada.
  def build_scenario!
    @vip = nil
    travel_to(Time.zone.parse("2026-10-20 10:00")) do
      @vip = vaccine_lot!(central, code: "22", doses: 100)
      send_and_receive!(@vip, 10)
    end
    travel_to(Time.zone.parse("2026-11-10 09:00")) do
      send_and_receive!(@vip, 30)
      @unit = vaccine_lot!(room, code: "42", doses: 5)
      first = open_vial!(room, lot: @vip, by: vaccinator)
      second = open_vial!(room, lot: @vip, by: vaccinator)
      apply_from_vial!(first, count: 10)
      apply_from_vial!(second, count: 3)
      result = Vaccination::CloseOutVial.call(vial: second, reason: "frasco aberto vencido na sala", by: lead)
      raise result.inspect if result.failure?

      adjust!(@vip, kind: "loss", quantity: "10", reason: "Frasco caiu no chão da sala", loss_code: "broken")
      adjust!(@vip, counted_quantity: "11")
      adjust!(@vip, counted_quantity: "20") # +9 acima do limite: pending, sem movimento
      keep = record!(room, vaccine_patient!(birth_date: Time.zone.today - 61), lot: @unit, by: vaccinator)
      record!(room, vaccine_patient!(birth_date: Time.zone.today - 62), lot: @unit, by: vaccinator)
      cancelled = Vaccination::CancelImmunization.call(immunization: keep, reason: "registrada na criança errada", replacement: nil, by: vaccinator)
      raise cancelled.inspect if cancelled.failure?
    end
  end

  def reconciled?(entry)
    entry["closing_balance"] == entry["opening_balance"] + entry["received"] + entry["transferred_in"] - entry["transferred_out"] -
      entry["vial_doses"] - entry["unit_doses"] + entry["adjustment"] - entry["physical_loss"].values.sum
  end

  describe "sala" do
    before { build_scenario!; sign_in_as(vaccinator) }

    it "um mês com todos os tipos de movimento: os números e a conta fecham com o razão" do
      summary(room_path, "2026-11")
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq(%w[month location rows])
      expect(json_body["month"]).to eq("2026-11")
      expect(json_body["location"]).to include("id" => room.stock_location_id, "kind" => "vaccine_room")

      vip = row_of("22")
      expect(vip).to include("immunobiological" => { "code" => "22", "name" => Vaccination::Immunobiologicals.find("22").name },
                             "lot" => include("id" => @vip.id, "number" => @vip.lot_number),
                             "opening_balance" => 10, "received" => 0, "transferred_in" => 30, "transferred_out" => 0,
                             "vials_opened" => 2, "doses_applied" => 13, "technical_loss" => 7,
                             "physical_loss" => { "broken" => 10 }, "vial_doses" => 20, "unit_doses" => 0, "adjustment" => 1,
                             "closing_balance" => 11)
      unit = row_of("42")
      expect(unit).to include("opening_balance" => 0, "received" => 5, "doses_applied" => 1, "unit_doses" => 1,
                              "vials_opened" => 0, "technical_loss" => 0, "physical_loss" => {}, "closing_balance" => 4)

      json_body["rows"].each do |entry|
        expect(reconciled?(entry)).to be(true), entry.inspect
        lot = StockLot.find(entry.dig("lot", "id"))
        expect(entry["closing_balance"]).to eq(balance_of(room.stock_location, lot))
      end
      expect(json_body["rows"].size).to eq(2)
    end

    it "perda pendente de aprovação não conta, nem no saldo nem na perda física" do
      expect(StockAdjustment.where(status: "pending").count).to eq(1)
      summary(room_path, "2026-11")
      expect(row_of("22")["adjustment"]).to eq(1)
      expect(row_of("22")["closing_balance"]).to eq(11)
    end

    it "o fechamento de outubro é a abertura de novembro" do
      summary(room_path, "2026-10")
      october = row_of("22")
      expect(october).to include("opening_balance" => 0, "transferred_in" => 10, "closing_balance" => 10, "vials_opened" => 0, "doses_applied" => 0)
      expect(reconciled?(october)).to be(true)
      summary(room_path, "2026-11")
      expect(row_of("22")["opening_balance"]).to eq(october["closing_balance"])
    end

    it "mês sem movimento: sem linhas, mas com o saldo que ficou nos meses seguintes" do
      summary(room_path, "2026-09")
      expect(json_body["rows"]).to eq([])
      summary(room_path, "2026-12")
      expect(row_of("22")).to include("opening_balance" => 11, "closing_balance" => 11, "transferred_in" => 0)
    end

    it "sem dado de paciente nem trilha de leitura" do
      expect { summary(room_path, "2026-11") }.not_to change { DomainEvent.where(name: "clinical_record.viewed").count }
      expect(response.body).not_to match(/patient|cpf|cns|full_name/i)
    end

    it "mês ausente ou inválido → 422 month" do
      [ nil, "", "2026-13", "2026-00", "2026-1", "202611", "2026-11-01", "abc", "1999-12" ].each do |month|
        summary(room_path, month)
        expect([ response.status, json_body ]).to eq([ 422, refusal("month") ]), "month=#{month.inspect}"
      end
      get room_path
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "outro parâmetro na query → 422" do
      get room_path, params: { month: "2026-11", cpf: "1" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "cpf" ])
    end
  end

  describe "acesso" do
    before { build_scenario! }

    it "qualquer papel da equipe da sala lê" do
      sign_in_as(lead)
      summary(room_path, "2026-11")
      expect(response).to have_http_status(:ok)
    end

    it "quem não é da sala, ou é de outra sala → 403; sala inexistente → 404" do
      sign_in_as(room_member!(vaccine_room!))
      summary(room_path, "2026-11")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(vaccinator)
      get "/vaccination/rooms/#{SecureRandom.uuid}/monthly_summary", params: { month: "2026-11" }
      expect(response).to have_http_status(:not_found)
    end

    it "o almoxarife da rede de frio não lê a sala, e a equipe da sala não lê a rede de frio" do
      sign_in_as(keeper)
      summary(room_path, "2026-11")
      expect(response).to have_http_status(:forbidden)
      sign_in_as(vaccinator)
      summary(central_path, "2026-11")
      expect(response).to have_http_status(:forbidden)
    end

    it "interruptor vaccination desligado → 403 feature_disabled" do
      sign_in_as(vaccinator)
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      summary(room_path, "2026-11")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vaccination" } ])
    end
  end

  describe "rede de frio" do
    before { build_scenario!; sign_in_as(keeper) }

    it "entrada, saída por transferência e saldo; sem aplicação, frasco nem perda técnica" do
      summary(central_path, "2026-11")
      expect(response).to have_http_status(:ok)
      expect(json_body["location"]).to include("id" => central.id, "kind" => "cold_chain_central")
      expect(json_body["rows"].size).to eq(1)
      expect(row_of("22")).to include("opening_balance" => 90, "received" => 0, "transferred_out" => 30, "transferred_in" => 0,
                                      "vials_opened" => 0, "doses_applied" => 0, "technical_loss" => 0, "physical_loss" => {},
                                      "closing_balance" => 60)
      expect(reconciled?(row_of("22"))).to be(true)
      summary(central_path, "2026-10")
      expect(row_of("22")).to include("opening_balance" => 0, "received" => 100, "transferred_out" => 10, "closing_balance" => 90)
    end

    it "mês inválido → 422 month" do
      summary(central_path, "2026-13")
      expect([ response.status, json_body ]).to eq([ 422, refusal("month") ])
    end
  end
end
