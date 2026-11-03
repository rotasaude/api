require "rails_helper"

# Módulo 30, revisão final C10 (ADR 0048): as escritas da frota (veículo,
# motorista, destino, viagem, série e passageiro) recusam chave de fora do
# corpo — no topo e nos objetos aninhados — com invalid_request no NOME da
# chave, como o TFD; nada é gravado.
RSpec.describe "Transporte — chave de fora do corpo", type: :request do
  let!(:city) { transport_city! }
  let(:dest) { destination! }
  let(:day) { Date.current + 2 }

  before { sign_in_as(dispatcher!) }

  def refused!(path)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => path)
  end

  it "veículo, motorista e destino: criar e alterar" do
    json_post "/transport/vehicles", plate: "ABC1D23", renavam: "12345678901", model: "Sprinter 416", kind: "van", seats: 15,
                                     wheelchair_spots: 1, color: "branca"
    refused!("color")
    expect(TransportVehicle.count).to eq(0)
    van = vehicle!
    json_patch "/transport/vehicles/#{van.id}", seats: 10, owner: "x"
    refused!("owner")
    expect(van.reload.seats).to eq(15)

    user = staff_with("davi-#{SecureRandom.hex(2)}@cidade.gov.br", "driver")
    json_post "/transport/drivers", user_id: user.id, license_number: "12345678901", license_category: "D",
                                    license_expires_on: (Date.current + 20).iso8601, cpf: "52998224725"
    refused!("cpf")
    expect(TransportDriver.count).to eq(0)

    json_post "/transport/destinations", ibge_code: "4113700", name: "Londrina", distance_km: 380, metropolitan: false, hospital: "x"
    refused!("hospital")
    json_patch "/transport/destinations/#{dest.id}", distance_km: 1, "a" * 100 => 1
    refused!("a" * 64)
    expect(dest.reload.distance_km).to eq(117)
  end

  it "viagem (e a parada aninhada), série (e o acompanhante) e passageiro (e o acompanhante)" do
    stops = [ { kind: "boarding", label: "Praça Central" }, { kind: "destination", destination_id: dest.id, note: "x" } ]
    json_post "/transport/trips", date: day.iso8601, departure_at: Time.zone.parse("#{day} 07:00").iso8601,
                                  return_at: Time.zone.parse("#{day} 18:00").iso8601, stops: stops, extra: 1
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("extra", "stops.1.note")
    expect(TransportTrip.count).to eq(0)

    patient = transport_patient!
    json_post "/transport/series", patient_id: patient.id, destination_id: dest.id, weekdays: [ 1 ], appointment_time: "07:00",
                                   departure_time: "05:30", return_time: "13:00", boarding_label: "Posto do Distrito",
                                   starts_on: day.iso8601, wheelchair: false, companion: { name: "Mãe do Paciente", cpf: "1" }
    refused!("companion.cpf")
    expect(TransportSeries.count).to eq(0)

    trip = trip!(date: day, destination: dest)
    stop = trip.transport_trip_stops.find_by!(kind: "boarding")
    json_post "/transport/trips/#{trip.id}/passengers", patient_id: patient.id, origin: "exception", exception_reason: "legacy_patient",
                                                        stop_id: stop.id, destination_id: dest.id, takes_seat: true, wheelchair: false,
                                                        cid10: "N185"
    refused!("cid10")
    json_post "/transport/trips/#{trip.id}/passengers", patient_id: patient.id, origin: "exception", exception_reason: "legacy_patient",
                                                        stop_id: stop.id, destination_id: dest.id, takes_seat: true, wheelchair: false,
                                                        companion: { name: "Mãe do Paciente", phone: "1" }
    refused!("companion.phone")
    expect(trip.transport_trip_passengers.count).to eq(0)
    expect(response.body).not_to include("N185")
  end
end
