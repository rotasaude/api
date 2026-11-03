require "rails_helper"

# Módulo 30, Task 14 (Desvio 8; Desvio 16; §14 T15): o aviso de viagem é a
# terceira fonte da caixa do wpda — `kind: "trip"` com as chaves exatas do
# T15, sem destino, prestador, CID nem placa; marca como lido e o
# unread_count cai.
RSpec.describe "Avisos de viagem na caixa do cidadão", type: :request do
  def body = JSON.parse(response.body)

  let!(:city) { transport_city! }
  let(:dest) { destination! }
  let(:vehicle) { vehicle! }
  let(:trip) { trip!(date: Date.current + 2, vehicle: vehicle, driver: driver_user!.transport_driver, status: "confirmed", destination: dest) }
  let(:patient) { transport_patient! }
  let(:citizen) { Patients::Pairs.of(patient).sole }
  let!(:rider) { passenger!(trip, patient: patient, provider_name: "Hospital do Rim Centro", address: "Rua das Clínicas, 10") }

  it "lista o aviso trip sem prestador, CID nem placa; marcar lido faz o unread_count cair" do
    expect(Transport::Notify.call(passenger: rider, kind: "added")).to eq(1)
    notice = TransportTripNotice.sole
    sign_in_citizen(citizen.phone)

    get "/citizen/notices"
    expect(response).to have_http_status(:ok)
    item = body["notices"].find { |n| n["kind"] == "trip" }
    departure = trip.departure_at.in_time_zone
    expect(item).to eq(
      "kind" => "trip", "id" => notice.id, "event" => "added", "date" => departure.to_date.iso8601,
      "departure_at" => departure.iso8601, "boarding" => { "label" => "Praça Central" }, "read" => false, "cpf_masked" => nil
    )
    expect(response.body).not_to include(dest.name, "Hospital do Rim", "Clínicas", vehicle.plate, "N18")
    expect(body["unread_count"]).to eq(1)

    json_post "/citizen/notices/#{notice.id}/read"
    expect(body).to eq("ok" => true)
    expect(notice.reload.read_at).to be_present

    get "/citizen/notices"
    expect(body["unread_count"]).to eq(0)
    expect(body["notices"].find { |n| n["kind"] == "trip" }["read"]).to be(true)
  end

  it "quem silenciou os avisos não conta no unread_count, mas o aviso continua na lista" do
    Transport::Notify.call(passenger: rider, kind: "added")
    CitizenContactPreference.create!(citizen_id: citizen.id, notices_muted: true)
    sign_in_citizen(citizen.phone)
    get "/citizen/notices"
    expect(body["notices"].map { |n| n["kind"] }).to eq([ "trip" ])
    expect(body["unread_count"]).to eq(0)
  end

  it "aviso de viagem de outro telefone: 404 na leitura e nada muda" do
    Transport::Notify.call(passenger: rider, kind: "added")
    notice = TransportTripNotice.sole
    sign_in_citizen("+5541990009999")
    json_post "/citizen/notices/#{notice.id}/read"
    expect(response).to have_http_status(:not_found)
    expect(notice.reload.read_at).to be_nil
  end
end
