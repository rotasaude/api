require "rails_helper"

# Módulo 30, Task 4 (ADR 0048; contrato §2, §4, §14 T4/T15/T19/T22; Review
# Focus 1): viagens da central — criar, alterar, confirmar e cancelar.
RSpec.describe "Transporte — viagens", type: :request do
  let!(:city) { transport_city! }
  let(:van) { vehicle!(seats: 15) }
  let(:driver) { driver_user!(category: "D").transport_driver }
  let(:dest) { destination! }
  let(:day) { Date.current + 2 }
  def at(hhmm) = Time.zone.parse("#{day} #{hhmm}").iso8601
  def body(dep, back, **over)
    { date: day.iso8601, departure_at: at(dep), return_at: at(back), vehicle_id: van.id, driver_id: driver.id,
      stops: [ { kind: "boarding", label: "Praça Central" }, { kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ] }.merge(over)
  end
  def trip_changed = DomainEvent.where(name: "transport.trip_changed")

  before { sign_in_as(dispatcher!) }

  it "Review Focus 1: encostadas valem; cruzando, veículo e motorista nas recusas juntos" do
    json_post "/transport/trips", body("07:00", "12:00")
    expect(response).to have_http_status(:created)
    json_post "/transport/trips", body("12:00", "15:00")
    expect(response).to have_http_status(:created)
    json_post "/transport/trips", body("11:59", "13:00")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"]).to contain_exactly({ "path" => "vehicle_id", "error" => "vehicle_overlap" }, { "path" => "driver_id", "error" => "driver_overlap" })
    expect(TransportTrip.count).to eq(2)
  end

  it "a corrida que escapa do Ruby vira 422 pela constraint, nunca 500" do
    json_post "/transport/trips", body("07:00", "12:00")
    allow(Transport::Overlap).to receive(:problems).and_return([])
    json_post "/transport/trips", body("08:00", "09:00")
    expect([ response.status, json_body["error"] ]).to eq([ 422, "vehicle_overlap" ])
    expect(json_body["problems"]).to eq([ { "path" => "vehicle_id", "error" => "vehicle_overlap" } ])
    other_van = vehicle!(seats: 15)
    json_post "/transport/trips", body("08:00", "09:00", vehicle_id: other_van.id)
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "driver_overlap", "driver_id" ])
    expect(TransportTrip.count).to eq(1)
  end

  it "planned sem escala; confirmar exige veículo, motorista, CNH válida na data e categoria D para mais de 8 lugares" do
    json_post "/transport/trips", body("07:00", "18:00", vehicle_id: nil, driver_id: nil)
    trip_id = json_body["id"]
    expect(json_body).to include("status" => "planned", "vehicle" => nil, "driver" => nil)
    json_post "/transport/trips/#{trip_id}/confirm"
    expect(json_body["problems"].map { |p| p["error"] }).to contain_exactly("vehicle_required", "driver_required")
    car_driver = driver_user!(category: "B", expires_on: day - 1).transport_driver
    json_patch "/transport/trips/#{trip_id}", vehicle_id: van.id, driver_id: car_driver.id
    expect(response).to have_http_status(:ok)
    json_post "/transport/trips/#{trip_id}/confirm"
    expect(json_body["problems"].map { |p| p["error"] }).to contain_exactly("driver_license_expired", "driver_license_category")
    expect(TransportTrip.find(trip_id).status).to eq("planned")
  end

  it "veículo inativo não confirma; CNH que vence no dia da viagem vale; confirmar publica trip_confirmed só com o id" do
    van.update!(active: false)
    json_post "/transport/trips", body("07:00", "18:00", driver_id: driver_user!(category: "D", expires_on: day).transport_driver.id)
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    expect(json_body["problems"]).to eq([ { "path" => "vehicle_id", "error" => "vehicle_inactive" } ])
    van.update!(active: true)
    expect { json_post "/transport/trips/#{id}/confirm" }.to change { DomainEvent.where(name: "transport.trip_confirmed").count }.by(1)
    expect(json_body["status"]).to eq("confirmed")
    expect(DomainEvent.where(name: "transport.trip_confirmed").last.payload).to eq("trip_id" => id)
    json_post "/transport/trips/#{id}/confirm"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_transition" ])
  end

  it "volta antes da ida, data fora do dia local e viagem de mais de 72 h" do
    json_post "/transport/trips", body("18:00", "07:00")
    expect(json_body["problems"]).to include({ "path" => "return_at", "error" => "return_before_departure" })
    json_post "/transport/trips", body("07:00", "18:00", date: (day + 1).iso8601)
    expect(json_body["problems"]).to include({ "path" => "date", "error" => "invalid_request" })
    json_post "/transport/trips", body("07:00", "07:01", return_at: (Time.zone.parse("#{day} 07:00") + 72.hours + 1.minute).iso8601)
    expect(json_body["problems"]).to include({ "path" => "return_at", "error" => "invalid_request" })
    json_post "/transport/trips", body("07:00", "07:01", return_at: (Time.zone.parse("#{day} 07:00") + 72.hours).iso8601)
    expect(response).to have_http_status(:created)
  end

  it "recusas de forma todas de uma vez; hora sem fuso e data ausente recusadas" do
    json_post "/transport/trips", { departure_at: "#{day}T07:00:00", return_at: at("18:00"), vehicle_id: "x", driver_id: SecureRandom.uuid,
                                    stops: [ { kind: "boarding", label: "ab" } ] }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("date", "departure_at", "vehicle_id", "driver_id", "stops.0.label", "stops")
    expect(TransportTrip.count).to eq(0)
  end

  it "a data é o dia LOCAL da saída (22:30 local já é o dia seguinte em UTC; T22) e a forma <trip> segue o contrato" do
    json_post "/transport/trips", body("22:30", "23:30", date: (day + 1).iso8601)
    expect(json_body["problems"]).to include({ "path" => "date", "error" => "invalid_request" })
    json_post "/transport/trips", body("22:30", "23:30")
    expect(response).to have_http_status(:created)
    trip = TransportTrip.find(json_body["id"])
    expect(trip.departure_at.utc.to_date).to eq(day + 1)
    expect(trip.date).to eq(day)
    expect(trip.departure_at.in_time_zone.strftime("%H:%M")).to eq("22:30")
    expect(json_body.keys).to match_array(%w[id date departure_at return_at vehicle driver status stops passengers occupancy series_id log])
    expect(json_body).to include("date" => day.iso8601, "departure_at" => at("22:30"), "series_id" => nil, "log" => nil, "passengers" => [])
    expect(json_body["vehicle"]).to eq("id" => van.id, "plate" => van.plate, "model" => van.model, "kind" => "van", "seats" => 15, "wheelchair_spots" => 1)
    expect(json_body["driver"]).to eq("id" => driver.id, "name" => Transport::Json.user_name(driver.user))
    expect(json_body["occupancy"]).to eq("seats_used" => 0, "seats" => 15, "wheelchair_used" => 0, "wheelchair_spots" => 1)
    expect(json_body["stops"].map { |s| s.except("id") }).to eq([
      { "position" => 1, "kind" => "boarding", "destination_id" => nil, "label" => "Praça Central" },
      { "position" => 2, "kind" => "destination", "destination_id" => dest.id, "label" => "Ponta Grossa" }
    ])
    expect(response.body).not_to include(driver.license_number)
  end

  it "paradas: position ordena; embarque antes do destino; rótulo vazio do destino vira o nome do município" do
    json_post "/transport/trips", body("07:00", "18:00", stops: [
      { position: 3, kind: "destination", label: "", destination_id: dest.id },
      { position: 1, kind: "boarding", label: "Praça" },
      { position: 2, kind: "boarding", label: "Distrito" }
    ])
    expect(response).to have_http_status(:created)
    expect(json_body["stops"].map { |s| [ s["position"], s["kind"], s["label"] ] })
      .to eq([ [ 1, "boarding", "Praça" ], [ 2, "boarding", "Distrito" ], [ 3, "destination", "Ponta Grossa" ] ])
    json_post "/transport/trips", body("07:00", "18:00", vehicle_id: nil, driver_id: nil,
                                       stops: [ { position: 1, kind: "boarding", label: "Praça" }, { position: 1, kind: "destination", label: "X", destination_id: dest.id } ])
    expect(json_body["problems"]).to include({ "path" => "stops.1.position", "error" => "invalid_request" })
    json_post "/transport/trips", body("07:00", "18:00", vehicle_id: nil, driver_id: nil,
                                       stops: [ { kind: "destination", label: "Ponta Grossa", destination_id: dest.id }, { kind: "boarding", label: "Praça" } ])
    expect(json_body["problems"]).to eq([ { "path" => "stops", "error" => "invalid_request" } ])
    json_post "/transport/trips", body("07:00", "18:00", vehicle_id: nil, driver_id: nil, stops: [ { kind: "boarding", label: "Praça" } ])
    expect(json_body["problems"]).to eq([ { "path" => "stops", "error" => "invalid_request" } ])
  end

  it "PATCH substitui as paradas, mantém as de id; parada com passageiro (mesmo retirado) não sai: 422 stop_in_use" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    boarding_id, destination_id = json_body["stops"].map { |s| s["id"] }
    json_patch "/transport/trips/#{id}", stops: [ { id: boarding_id, kind: "boarding", label: "Praça Central" }, { kind: "boarding", label: "Distrito Norte" },
                                                  { id: destination_id, kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ]
    expect(response).to have_http_status(:ok)
    expect(json_body["stops"].map { |s| [ s["position"], s["label"] ] }).to eq([ [ 1, "Praça Central" ], [ 2, "Distrito Norte" ], [ 3, "Ponta Grossa" ] ])
    expect(json_body["stops"].values_at(0, 2).map { |s| s["id"] }).to eq([ boarding_id, destination_id ])
    trip = TransportTrip.find(id)
    p = passenger!(trip)
    p.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Paciente desistiu da viagem")
    json_patch "/transport/trips/#{id}", stops: [ { kind: "boarding", label: "Rodoviária" }, { id: destination_id, kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ]
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "stop_in_use", "stops" ])
    expect(TransportTripStop.where(transport_trip_id: id).pluck(:label)).to contain_exactly("Praça Central", "Distrito Norte", "Ponta Grossa")
    json_patch "/transport/trips/#{id}", stops: [ { id: SecureRandom.uuid, kind: "boarding", label: "Praça" }, { id: destination_id, kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ]
    expect(json_body["problems"]).to include({ "path" => "stops.0.id", "error" => "invalid_request" })
  end

  it "a guarda do banco também vira stop_in_use (nunca 500) se a conferência do Ruby escapar" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    destination_id = json_body["stops"].last["id"]
    passenger!(TransportTrip.find(id))
    allow(Transport::SaveTrip).to receive(:stops_in_use?).and_return(false)
    json_patch "/transport/trips/#{id}", stops: [ { kind: "boarding", label: "Rodoviária" }, { id: destination_id, kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ]
    expect([ response.status, json_body["error"] ]).to eq([ 422, "stop_in_use" ])
  end

  it "troca de veículo com passageiros confere a lotação nova" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    trip = TransportTrip.find(id)
    passenger!(trip, wheelchair: true)
    passenger!(trip, companion_name: "Ana Acompanhante", companion_attendance: "pending")
    get "/transport/trips", params: { date: day.iso8601 }
    expect(json_body["items"].first["occupancy"]).to eq("seats_used" => 3, "seats" => 15, "wheelchair_used" => 1, "wheelchair_spots" => 1)
    car = vehicle!(seats: 2, wheelchair_spots: 0, kind: "car")
    json_patch "/transport/trips/#{id}", vehicle_id: car.id
    expect(json_body["problems"]).to contain_exactly({ "path" => "vehicle_id", "error" => "seats_full" }, { "path" => "vehicle_id", "error" => "wheelchair_full" })
    expect(trip.reload.transport_vehicle_id).to eq(van.id)
  end

  it "confirmada: PATCH não anula veículo nem motorista e troca só com as regras do confirm" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    json_patch "/transport/trips/#{id}", vehicle_id: nil, driver_id: nil
    expect(json_body["problems"].map { |p| p["error"] }).to contain_exactly("vehicle_required", "driver_required")
    json_patch "/transport/trips/#{id}", driver_id: driver_user!(category: "B").transport_driver.id
    expect(json_body["problems"]).to eq([ { "path" => "driver_id", "error" => "driver_license_category" } ])
    expect(TransportTrip.find(id).transport_driver_id).to eq(driver.id)
  end

  it "T29: motorista inativo → 422 driver_inactive (criar, PATCH e confirmar)" do
    gone = driver_user!(category: "D").transport_driver
    gone.update!(active: false)
    json_post "/transport/trips", body("07:00", "18:00", driver_id: gone.id)
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "driver_inactive", "driver_id" ])
    expect(json_body["problems"]).to eq([ { "path" => "driver_id", "error" => "driver_inactive" } ])
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    json_patch "/transport/trips/#{id}", driver_id: gone.id
    expect(json_body["problems"]).to eq([ { "path" => "driver_id", "error" => "driver_inactive" } ])
    driver.update!(active: false)
    json_post "/transport/trips/#{id}/confirm"
    expect(json_body["problems"]).to eq([ { "path" => "driver_id", "error" => "driver_inactive" } ])
  end

  it "T29: confirmada com motorista inativo — PATCH que o troca por um válido passa" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    driver.update!(active: false)
    json_patch "/transport/trips/#{id}", departure_at: at("08:00")
    expect(json_body["problems"]).to eq([ { "path" => "driver_id", "error" => "driver_inactive" } ])
    json_patch "/transport/trips/#{id}", driver_id: driver_user!(category: "D").transport_driver.id
    expect(response).to have_http_status(:ok)
  end

  it "T29: confirmada com CNH vencida ou categoria errada — PATCH que troca o motorista por um válido passa" do
    expired = driver_user!(category: "D", expires_on: day + 30).transport_driver
    json_post "/transport/trips", body("07:00", "18:00", driver_id: expired.id)
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    expired.update!(license_expires_on: day - 1, license_category: "B")
    json_patch "/transport/trips/#{id}", departure_at: at("08:00")
    expect(json_body["problems"].map { |p| p["error"] }).to contain_exactly("driver_license_expired", "driver_license_category")
    json_patch "/transport/trips/#{id}", driver_id: driver_user!(category: "D").transport_driver.id
    expect(response).to have_http_status(:ok)
  end

  it "T29: confirmada com veículo inativo — PATCH que o troca por um ativo passa" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    van.update!(active: false)
    json_patch "/transport/trips/#{id}", departure_at: at("08:00")
    expect(json_body["problems"]).to eq([ { "path" => "vehicle_id", "error" => "vehicle_inactive" } ])
    json_patch "/transport/trips/#{id}", vehicle_id: vehicle!(seats: 15).id
    expect(response).to have_http_status(:ok)
  end

  it "T29: cancelar nunca roda as regras do confirm — motorista ou veículo inativo cancela" do
    json_post "/transport/trips", body("07:00", "12:00")
    a = json_body["id"]
    json_post "/transport/trips/#{a}/confirm"
    driver.update!(active: false)
    json_post "/transport/trips/#{a}/cancel", reason: "Motorista desligado da frota"
    expect([ response.status, json_body["status"] ]).to eq([ 200, "cancelled" ])
    other_van = vehicle!(seats: 15)
    other_driver = driver_user!(category: "D").transport_driver
    json_post "/transport/trips", body("07:00", "12:00", vehicle_id: other_van.id, driver_id: other_driver.id)
    b = json_body["id"]
    json_post "/transport/trips/#{b}/confirm"
    other_van.update!(active: false)
    json_post "/transport/trips/#{b}/cancel", reason: "Veículo baixado da frota"
    expect([ response.status, json_body["status"] ]).to eq([ 200, "cancelled" ])
  end

  it "cancelar exige motivo, avisa por evento e libera o veículo" do
    json_post "/transport/trips", body("07:00", "12:00")
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    json_post "/transport/trips/#{id}/cancel", reason: "curto"
    expect(json_body["path"]).to eq("reason")
    expect { json_post "/transport/trips/#{id}/cancel", reason: "Veículo quebrado na véspera" }
      .to change { DomainEvent.where(name: "transport.trip_cancelled").count }.by(1)
    expect(json_body["status"]).to eq("cancelled")
    expect(DomainEvent.where(name: "transport.trip_cancelled").last.payload).to eq("trip_id" => id)
    expect(DomainEvent.where(name: "transport.trip_cancelled").last.payload.to_s).not_to include("quebrado")
    json_post "/transport/trips", body("08:00", "09:00")
    expect(response).to have_http_status(:created)
  end

  it "cancelar uma planned também publica trip_cancelled (só o id); sem confirmed_at, o consumidor não avisa (T15)" do
    json_post "/transport/trips", body("07:00", "12:00")
    id = json_body["id"]
    expect { json_post "/transport/trips/#{id}/cancel", reason: "Agenda do hospital remarcada" }
      .to change { DomainEvent.where(name: "transport.trip_cancelled").count }.by(1)
    expect([ response.status, json_body["status"] ]).to eq([ 200, "cancelled" ])
    expect(DomainEvent.where(name: "transport.trip_cancelled").last.payload).to eq("trip_id" => id)
    expect(TransportTrip.find(id).confirmed_at).to be_nil
  end

  it "done/cancelled → trip_not_open em PATCH, confirm e cancel; in_progress → invalid_transition" do
    done = trip!(date: day, vehicle: van, driver: driver, status: "done")
    cancelled = TransportTrip.create!(departure_at: Time.zone.parse("#{day + 5} 07:00"), return_at: Time.zone.parse("#{day + 5} 09:00"),
                                      status: "cancelled", cancelled_at: Time.current, created_by_user: dispatcher!)
    running = trip!(date: day + 1, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "in_progress")
    [ done, cancelled ].each do |t|
      json_patch "/transport/trips/#{t.id}", departure_at: at("06:00")
      expect(json_body["error"]).to eq("trip_not_open")
      json_post "/transport/trips/#{t.id}/confirm"
      expect(json_body["error"]).to eq("trip_not_open")
      json_post "/transport/trips/#{t.id}/cancel", reason: "Motivo qualquer do teste"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "trip_not_open" ])
    end
    json_patch "/transport/trips/#{running.id}", departure_at: at("06:00")
    expect(json_body["error"]).to eq("invalid_transition")
    json_post "/transport/trips/#{running.id}/cancel", reason: "Motivo qualquer do teste"
    expect(json_body["error"]).to eq("invalid_transition")
    json_post "/transport/trips/#{running.id}/confirm"
    expect(json_body["error"]).to eq("invalid_transition")
    expect(running.reload.status).to eq("in_progress")
  end

  # Task 14, Ruling I-2: toda mudança da saída publica; o limiar de 30 min é
  # do consumidor dos avisos (compara com o último valor avisado).
  it "toda mudança da saída na confirmada publica trip_changed; a mesma saída reenviada não" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    json_post "/transport/trips/#{id}/confirm"
    expect { json_patch "/transport/trips/#{id}", departure_at: at("07:00") }.not_to(change { trip_changed.count })
    expect { json_patch "/transport/trips/#{id}", departure_at: at("07:10") }.to change { trip_changed.count }.by(1)
    expect(trip_changed.last.payload).to eq("trip_id" => id, "change" => "departure")
  end

  it "na planned a saída muda sem aviso; rótulo de embarque mudado na confirmada publica trip_changed boarding com o stop_id" do
    json_post "/transport/trips", body("07:00", "18:00")
    id = json_body["id"]
    expect { json_patch "/transport/trips/#{id}", departure_at: at("09:00") }.not_to(change { trip_changed.count })
    json_post "/transport/trips/#{id}/confirm"
    boarding_id, destination_id = json_body["stops"].map { |s| s["id"] }
    same = [ { id: boarding_id, kind: "boarding", label: "Praça Central" }, { id: destination_id, kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ]
    expect { json_patch "/transport/trips/#{id}", stops: same }.not_to(change { trip_changed.count })
    moved = [ { id: boarding_id, kind: "boarding", label: "Rodoviária" }, { id: destination_id, kind: "destination", label: "Ponta Grossa", destination_id: dest.id } ]
    expect { json_patch "/transport/trips/#{id}", stops: moved }.to change { trip_changed.count }.by(1)
    expect(trip_changed.last.payload).to eq("trip_id" => id, "change" => "boarding", "stop_id" => boarding_id)
  end

  it "GET exige date; filtra por veículo; ordena pela saída; escopo da central" do
    json_post "/transport/trips", body("10:00", "12:00")
    late = json_body["id"]
    json_post "/transport/trips", body("06:00", "08:00", vehicle_id: nil, driver_id: nil)
    early = json_body["id"]
    get "/transport/trips"
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "date" ])
    get "/transport/trips", params: { date: "31/12/2026" }
    expect(json_body["path"]).to eq("date")
    get "/transport/trips", params: { date: day.iso8601 }
    expect(json_body["items"].map { |t| t["id"] }).to eq([ early, late ])
    get "/transport/trips", params: { date: day.iso8601, vehicle_id: van.id }
    expect(json_body["items"].map { |t| t["id"] }).to eq([ late ])
    get "/transport/trips", params: { date: (day + 1).iso8601 }
    expect(json_body["items"]).to eq([])
    json_patch "/transport/trips/#{SecureRandom.uuid}", departure_at: at("06:00")
    expect(response).to have_http_status(:not_found)
  end

  it "motorista e comissão → 403 missing_role; transporte desligado → 403 feature_disabled" do
    [ driver_user!, committee! ].each do |user|
      sign_in_as(user)
      get "/transport/trips", params: { date: day.iso8601 }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      json_post "/transport/trips", body("07:00", "12:00")
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
    sign_in_as(dispatcher!)
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    get "/transport/trips", params: { date: day.iso8601 }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "sanitary_transport")
  end
end
