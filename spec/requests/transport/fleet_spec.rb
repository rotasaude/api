require "rails_helper"

# Módulo 30, Task 3 (ADR 0048; contrato §2, §4, §14 T3/T18/T19): frota,
# motoristas, destinos e candidatos a motorista, só para a central.
RSpec.describe "Transporte — frota", type: :request do
  let!(:city) { transport_city! }

  before { sign_in_as(dispatcher!) }

  def van(overrides = {})
    { plate: "abc-1d23", renavam: "12345678901", model: "Sprinter 416", kind: "van", seats: 15, wheelchair_spots: 1, cnes: "1234567" }.merge(overrides)
  end

  def driver_body(user, overrides = {})
    { user_id: user.id, license_number: "12345678901", license_category: "D", license_expires_on: (Date.current + 20).iso8601 }.merge(overrides)
  end

  it "cadastra veículo com placa Mercosul normalizada; placa repetida → 409" do
    json_post "/transport/vehicles", van
    expect(response).to have_http_status(:created)
    expect(json_body).to include("plate" => "ABC1D23", "kind" => "van", "renem_code" => nil, "active" => true, "cnes" => "1234567")
    json_post "/transport/vehicles", van(plate: "ABC1D23", renavam: "10987654321", model: "Outro", wheelchair_spots: 0)
    expect([ response.status, json_body["error"] ]).to eq([ 409, "plate_taken" ])
  end

  it "RENAVAM repetido → 409 renavam_taken e nada é gravado" do
    json_post "/transport/vehicles", van
    json_post "/transport/vehicles", van(plate: "BRA2E19")
    expect([ response.status, json_body["error"] ]).to eq([ 409, "renavam_taken" ])
    expect(TransportVehicle.count).to eq(1)
  end

  it "recusas do veículo todas de uma vez" do
    json_post "/transport/vehicles", plate: "XX", renavam: "1", model: "", kind: "truck", seats: 0, wheelchair_spots: 11
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("invalid_request")
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("plate", "renavam", "model", "kind", "seats", "wheelchair_spots")
    expect(TransportVehicle.count).to eq(0)
  end

  it "modelo de 1 e de 81 caracteres é recusado; 2 e 80 passam (T18)" do
    [ "A", "A" * 81 ].each do |model|
      json_post "/transport/vehicles", van(model: model)
      expect(json_body["problems"].map { |p| p["path"] }).to eq([ "model" ])
    end
    json_post "/transport/vehicles", van(model: "AB")
    expect(response).to have_http_status(:created)
    json_post "/transport/vehicles", van(model: "A" * 80, plate: "BRA2E19", renavam: "10987654321")
    expect(response).to have_http_status(:created)
  end

  it "edita o veículo (PATCH parcial), desativa, e a lista filtra por ?active=true, ordenada pela placa" do
    json_post "/transport/vehicles", van(plate: "ZZZ9Z99", renavam: "11111111111")
    last = json_body
    json_post "/transport/vehicles", van(plate: "AAA1A11", renavam: "22222222222")
    first = json_body
    json_patch "/transport/vehicles/#{last['id']}", seats: 12, active: false
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("seats" => 12, "active" => false, "plate" => "ZZZ9Z99")
    get "/transport/vehicles"
    expect(json_body["items"].map { |v| v["plate"] }).to eq(%w[AAA1A11 ZZZ9Z99])
    get "/transport/vehicles?active=true"
    expect(json_body["items"].map { |v| v["id"] }).to eq([ first["id"] ])
    json_patch "/transport/vehicles/#{last['id']}", plate: "AAA1A11"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "plate_taken" ])
    json_patch "/transport/vehicles/#{SecureRandom.uuid}", seats: 3
    expect(response).to have_http_status(:not_found)
  end

  it "motorista: só usuário com papel driver; CNH nunca sai inteira; status pela validade" do
    user = staff_with("davi@cidade.gov.br", "driver")
    other = staff_with("ana@cidade.gov.br", "viewer")
    json_post "/transport/drivers", driver_body(other)
    expect([ response.status, json_body["error"] ]).to eq([ 422, "user_not_driver" ])
    expect(TransportDriver.count).to eq(0)
    json_post "/transport/drivers", driver_body(user)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("license_status" => "expiring", "license_number_last4" => "8901", "user" => { "id" => user.id, "name" => "davi@cidade.gov.br" })
    expect(response.body).not_to include("12345678901")
    get "/transport/drivers"
    expect(response.body).not_to include("12345678901")
    expect(json_body["items"].first).to include("license_number_last4" => "8901")
  end

  it "motorista já cadastrado → 409 user_already_driver; membership driver revogada → user_not_driver" do
    user = staff_with("davi@cidade.gov.br", "driver")
    json_post "/transport/drivers", driver_body(user)
    json_post "/transport/drivers", driver_body(user, license_number: "99999999999")
    expect([ response.status, json_body["error"] ]).to eq([ 409, "user_already_driver" ])
    revoked = staff_with("rev@cidade.gov.br", "driver")
    revoked.memberships.update_all(revoked_at: Time.current)
    json_post "/transport/drivers", driver_body(revoked)
    expect([ response.status, json_body["error"] ]).to eq([ 422, "user_not_driver" ])
  end

  it "status da CNH: expired, expiring (até 30 dias) e valid" do
    expect(Transport::Json.driver(TransportDriver.new(license_number: "12345678901", license_expires_on: Date.current - 1,
                                                      license_category: "B", user: User.new), today: Date.current)["license_status"]).to eq("expired")
    { 0 => "expiring", 30 => "expiring", 31 => "valid" }.each do |days, status|
      driver = TransportDriver.new(license_number: "12345678901", license_expires_on: Date.current + days, license_category: "B", user: User.new)
      expect(Transport::Json.driver(driver, today: Date.current)["license_status"]).to eq(status)
    end
  end

  it "recusas do motorista: categoria, validade e CNH malformadas, todas de uma vez" do
    user = staff_with("davi@cidade.gov.br", "driver")
    json_post "/transport/drivers", driver_body(user, license_number: "123", license_category: "A", license_expires_on: "amanhã")
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("license_number", "license_category", "license_expires_on")
  end

  it "edita a CNH do motorista e o desativa; o usuário não muda" do
    user = staff_with("davi@cidade.gov.br", "driver")
    json_post "/transport/drivers", driver_body(user)
    id = json_body["id"]
    json_patch "/transport/drivers/#{id}", license_category: "E", license_expires_on: (Date.current + 400).iso8601, active: false
    expect(json_body).to include("license_category" => "E", "license_status" => "valid", "active" => false, "license_number_last4" => "8901")
    json_patch "/transport/drivers/#{id}", user_id: staff_with("outro@cidade.gov.br", "driver").id
    expect(json_body["problems"].map { |p| p["path"] }).to eq([ "user_id" ])
    get "/transport/drivers?active=true"
    expect(json_body["items"]).to eq([])
  end

  it "driver_candidates: driver sem cadastro aparece; depois do POST some; viewer e membership revogada nunca" do
    user = staff_with("davi@cidade.gov.br", "driver")
    staff_with("ana@cidade.gov.br", "viewer")
    revoked = staff_with("rev@cidade.gov.br", "driver")
    revoked.memberships.update_all(revoked_at: Time.current)
    get "/transport/driver_candidates"
    expect(json_body).to eq("items" => [ { "user_id" => user.id, "name" => "davi@cidade.gov.br" } ])
    json_post "/transport/drivers", driver_body(user)
    get "/transport/driver_candidates"
    expect(json_body["items"]).to eq([])
  end

  it "destino com IBGE e km; intramunicipal com 0 km; IBGE repetido → 409; papel errado → 403" do
    json_post "/transport/destinations", ibge_code: "4106902", name: "Curitiba", distance_km: 0, metropolitan: false
    expect(response).to have_http_status(:created)
    expect(json_body).to include("ibge_code" => "4106902", "distance_km" => 0, "metropolitan" => false, "active" => true)
    json_post "/transport/destinations", ibge_code: "4106902", name: "Outro", distance_km: 5
    expect([ response.status, json_body["error"] ]).to eq([ 409, "ibge_taken" ])
    json_post "/transport/destinations", ibge_code: "41", name: "", distance_km: -1, metropolitan: "sim"
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("ibge_code", "name", "distance_km", "metropolitan")
    sign_in_as(committee!)
    get "/transport/destinations"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    get "/transport/driver_candidates"
    expect(response).to have_http_status(:forbidden)
  end

  it "edita o destino, lista por nome e filtra ?active=true" do
    json_post "/transport/destinations", ibge_code: "4119905", name: "Ponta Grossa", distance_km: 117, metropolitan: false
    id = json_body["id"]
    json_post "/transport/destinations", ibge_code: "4101804", name: "Araucária", distance_km: 27, metropolitan: true
    json_patch "/transport/destinations/#{id}", active: false, distance_km: 120
    expect(json_body).to include("active" => false, "distance_km" => 120)
    get "/transport/destinations"
    expect(json_body["items"].map { |d| d["name"] }).to eq(%w[Araucária Ponta\ Grossa])
    get "/transport/destinations?active=true"
    expect(json_body["items"].map { |d| d["name"] }).to eq([ "Araucária" ])
  end

  it "com sanitary_transport desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/transport/vehicles"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end

  it "cada gravação publica um evento só com ids" do
    events = []
    allow(DomainEvents).to receive(:publish) { |name, **payload| events << [ name, payload ] }
    user = staff_with("davi@cidade.gov.br", "driver")
    json_post "/transport/vehicles", van
    json_post "/transport/drivers", driver_body(user)
    json_post "/transport/destinations", ibge_code: "4106902", name: "Curitiba", distance_km: 0
    saved = events.select { |name, _| name.start_with?("transport.") }
    expect(saved.map(&:first)).to eq(%w[transport.vehicle_saved transport.driver_saved transport.destination_saved])
    expect(saved.flat_map { |_, payload| payload.keys }).to all(satisfy { |key| key.to_s.end_with?("_id") })
  end
end
