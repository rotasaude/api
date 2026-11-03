require "rails_helper"

# Módulo 30, Task 8 (ADR 0048; contrato §2, §5; §14 T18, T19): tela do
# motorista — só as próprias viagens, sem CNS nem CPF; saída só da confirmada
# e só no dia; presença do paciente e do acompanhante; fechamento com o diário
# de bordo e o evento transport.trip_done (só o id).
RSpec.describe "Transporte — motorista", type: :request do
  let!(:city) { transport_city! }
  let(:davi) { driver_user! }
  let(:trip) { trip!(date: Date.current, vehicle: vehicle!, driver: davi.transport_driver, status: "confirmed") }
  let!(:rider) { passenger!(trip, companion_name: "Acompanhante", companion_attendance: "pending") }
  let(:valid_close) { { odometer_start: 1000, odometer_end: 1240, fuel: [], expenses: [] } }

  def start!(t = trip) = json_post("/transport/my_trips/#{t.id}/start")
  def attend!(items, t = trip) = json_post("/transport/my_trips/#{t.id}/attendance", items: items)
  def close!(body, t = trip) = json_post("/transport/my_trips/#{t.id}/close", body)

  before { sign_in_as(davi) }

  it "vê só as próprias viagens do dia, sem CNS nem CPF" do
    trip!(date: Date.current, vehicle: vehicle!(plate_seed: 2), driver: driver_user!.transport_driver, status: "confirmed")
    get "/transport/my_trips"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { |t| t["id"] }).to eq([ trip.id ])
    expect(json_body["items"][0]["passengers"][0]["patient"].keys).to contain_exactly("id", "display_name", "phone_masked")
    cpf = rider.patient.cpf
    expect(cpf).to be_present
    expect(response.body).not_to include(cpf)
    expect(response.body).not_to include("cns_masked", "has_cpf")
  end

  it "?date= escolhe o dia; data malformada → 422 com path" do
    later = trip!(date: Date.current + 2, vehicle: vehicle!(plate_seed: 5), driver: davi.transport_driver, status: "confirmed")
    get "/transport/my_trips", params: { date: (Date.current + 2).iso8601 }
    expect(json_body["items"].map { |t| t["id"] }).to eq([ later.id ])
    get "/transport/my_trips", params: { date: "2026-02-30" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "date")
  end

  it "sai, marca presença do paciente e do acompanhante e fecha; pendente bloqueia o fechamento" do
    start!
    expect(json_body["status"]).to eq("in_progress")
    attend!([ { passenger_id: rider.id, attendance: "boarded" } ])
    expect(json_body["passengers"][0]).to include("attendance" => "boarded", "companion_attendance" => "pending")
    close!(valid_close)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("attendance_pending")
    attend!([ { passenger_id: rider.id, attendance: "boarded", companion_attendance: "no_show" } ])
    close!(odometer_start: 1240, odometer_end: 1000, fuel: [], expenses: [])
    expect(json_body["error"]).to eq("odometer_invalid")
    expect(trip.reload.status).to eq("in_progress")
    expect do
      close!(odometer_start: 1000, odometer_end: 1240,
             fuel: [ { liters: 40.5, amount_cents: 25_000, station: "Posto Rota" } ], expenses: [ { kind: "toll", amount_cents: 1250, note: nil } ])
    end.to change { DomainEvent.where(name: "transport.trip_done").count }.by(1)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "done")
    expect(json_body["log"]).to include("odometer_start" => 1000, "odometer_end" => 1240,
                                        "closed_by_name" => Transport::Json.user_name(davi),
                                        "fuel" => [ { "liters" => 40.5, "amount_cents" => 25_000, "station" => "Posto Rota" } ],
                                        "expenses" => [ { "kind" => "toll", "amount_cents" => 1250, "note" => nil } ])
    expect(DomainEvent.where(name: "transport.trip_done").map(&:payload)).to include({ "trip_id" => trip.id })
    expect(TransportTripLog.where(transport_trip: trip).count).to eq(1)
  end

  it "o passageiro retirado não bloqueia o fechamento e o fechamento chama Tfd::FleetLegs.complete! com a viagem" do
    gone = passenger!(trip)
    gone.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Desistiu da viagem")
    start!
    attend!([ { passenger_id: rider.id, attendance: "no_show", companion_attendance: "no_show" } ])
    expect(Tfd::FleetLegs).to receive(:complete!).with(trip).and_call_original
    close!(valid_close)
    expect(json_body["status"]).to eq("done")
  end

  it "presença: só em viagem em andamento; passageiro de outra viagem → 404; acompanhante só onde há; tudo ou nada" do
    attend!([ { passenger_id: rider.id, attendance: "boarded" } ])
    expect(json_body["error"]).to eq("invalid_transition")
    start!
    other_trip = trip!(date: Date.current + 3, vehicle: vehicle!(plate_seed: 6), driver: davi.transport_driver, status: "confirmed")
    stranger = passenger!(other_trip)
    attend!([ { passenger_id: rider.id, attendance: "boarded" }, { passenger_id: stranger.id, attendance: "boarded" } ])
    expect(response).to have_http_status(:not_found)
    expect(rider.reload.attendance).to eq("pending")
    lonely = passenger!(trip)
    attend!([ { passenger_id: lonely.id, attendance: "boarded", companion_attendance: "boarded" } ])
    expect(json_body).to include("error" => "invalid_request", "path" => "items.0.companion_attendance")
    attend!([ { passenger_id: rider.id, attendance: "sleeping" } ])
    expect(json_body).to include("error" => "invalid_request", "path" => "items.0.attendance")
    attend!([])
    expect(json_body).to include("error" => "invalid_request", "path" => "items")
    expect(lonely.reload.attendance).to eq("pending")
  end

  it "não sai em viagem de amanhã; viagem de outro motorista → 404" do
    tomorrow = trip!(date: Date.current + 1, vehicle: vehicle!(plate_seed: 3), driver: davi.transport_driver, status: "confirmed")
    start!(tomorrow)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("trip_not_today")
    other = trip!(date: Date.current, vehicle: vehicle!(plate_seed: 4), driver: driver_user!.transport_driver, status: "confirmed")
    start!(other)
    expect(response).to have_http_status(:not_found)
    close!(valid_close, other)
    expect(response).to have_http_status(:not_found)
    expect(other.reload.status).to eq("confirmed")
  end

  it "saída só da confirmada (planned → 404, FW1; em andamento → invalid_transition) e publica transport.trip_started só com o id" do
    planned = trip!(date: Date.current, departure: "19:00", back: "21:00", vehicle: vehicle!(plate_seed: 7), driver: davi.transport_driver)
    start!(planned)
    expect(response).to have_http_status(:not_found)
    expect { start! }.to change { DomainEvent.where(name: "transport.trip_started").count }.by(1)
    expect(DomainEvent.where(name: "transport.trip_started").map(&:payload)).to include({ "trip_id" => trip.id })
    expect(trip.reload.started_at).to be_present
    start!
    expect(json_body["error"]).to eq("invalid_transition")
  end

  it "fechamento: só em andamento; recusa abastecimento e despesa fora dos limites, todas de uma vez" do
    close!(valid_close)
    expect(json_body["error"]).to eq("invalid_transition")
    start!
    attend!([ { passenger_id: rider.id, attendance: "boarded", companion_attendance: "boarded" } ])
    close!(valid_close.merge(fuel: [ { liters: 0, amount_cents: 100, station: "Posto" }, { liters: 10.125, amount_cents: 100, station: "Posto" },
                                     { liters: 1000.01, amount_cents: 0, station: "" } ],
                             expenses: [ { kind: "lodging", amount_cents: 100, note: nil }, { kind: "meal", amount_cents: 100, note: "x" * 121 } ]))
    expect(json_body["error"]).to eq("invalid_request")
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly(
      "fuel.0.liters", "fuel.1.liters", "fuel.2.liters", "fuel.2.amount_cents", "fuel.2.station", "expenses.0.kind", "expenses.1.note"
    )
    close!(valid_close.merge(fuel: Array.new(21) { { liters: 1, amount_cents: 100, station: "Posto" } }))
    expect(json_body).to include("error" => "invalid_request", "path" => "fuel")
    close!(valid_close.merge(odometer_end: 10_000_000))
    expect(json_body).to include("error" => "odometer_invalid", "path" => "odometer_end")
    expect(trip.reload.status).to eq("in_progress")
    close!(valid_close.merge(fuel: [ { liters: 1000, amount_cents: 10_000_000, station: "P" * 120 } ],
                             expenses: [ { kind: "other", amount_cents: 1, note: "Lavagem da van" } ]))
    expect(json_body["status"]).to eq("done")
    close!(valid_close)
    expect(json_body["error"]).to eq("trip_not_open")
  end

  it "só o motorista cadastrado; a central → 403" do
    sign_in_as(dispatcher!)
    get "/transport/my_trips"
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("missing_role")
  end
end
