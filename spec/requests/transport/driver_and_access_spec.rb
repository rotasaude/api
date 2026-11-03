require "rails_helper"

# Módulo 30, onda final FW1, FW2 e FW4 (ADR 0048; contrato §4, §5; §14 T19,
# T34): o motorista só vê e só opera viagens confirmadas, em andamento ou
# feitas; a saída confere de novo a CNH (validade na data e categoria); sem
# sessão, as rotas da central respondem 401.
RSpec.describe "Transporte — tela do motorista e acesso", type: :request do
  let!(:city) { transport_city! }
  let(:davi) { driver_user!(category: "D") }

  # Uma viagem por hora do dia: o mesmo motorista não pode estar em duas que se cruzam.
  def trip_for(status, driver: davi, seats: 15, date: Date.current)
    @hour = (@hour || 5) + 1
    trip!(date: date, departure: format("%02d:00", @hour), back: format("%02d:30", @hour), vehicle: vehicle!(seats: seats),
          driver: driver.transport_driver, status: status)
  end

  describe "FW1: só confirmed, in_progress e done" do
    before { sign_in_as(davi) }

    it "a lista não traz planned nem cancelled; start/attendance/close nelas → 404" do
      shown = %w[confirmed in_progress done].map { |status| trip_for(status) }
      hidden = [ trip_for("planned"), trip_for("planned") ]
      hidden.last.update_columns(status: "cancelled", cancelled_at: Time.current)
      get "/transport/my_trips"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |t| t["id"] }).to match_array(shown.map(&:id))

      hidden.each do |trip|
        json_post "/transport/my_trips/#{trip.id}/start"
        expect(response).to have_http_status(:not_found)
        json_post "/transport/my_trips/#{trip.id}/attendance", items: []
        expect(response).to have_http_status(:not_found)
        json_post "/transport/my_trips/#{trip.id}/close", odometer_start: 1, odometer_end: 2
        expect(response).to have_http_status(:not_found)
      end
      expect(hidden.map { |t| t.reload.status }).to eq(%w[planned cancelled])
    end
  end

  describe "FW2: a saída confere a CNH de novo" do
    before { sign_in_as(davi) }

    it "CNH vencida antes do dia da viagem → 422 driver_license_expired; a viagem fica confirmed" do
      trip = trip_for("confirmed")
      davi.transport_driver.update_columns(license_expires_on: Date.current - 1)
      json_post "/transport/my_trips/#{trip.id}/start"
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "driver_license_expired", "driver_id" ])
      expect(trip.reload.status).to eq("confirmed")
    end

    it "categoria B num veículo de mais de 8 lugares → driver_license_category; a CNH que vence hoje e a categoria certa saem" do
      trip = trip_for("confirmed", seats: 15)
      davi.transport_driver.update_columns(license_category: "B")
      json_post "/transport/my_trips/#{trip.id}/start"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "driver_license_category" ])

      davi.transport_driver.update_columns(license_category: "D", license_expires_on: Date.current)
      json_post "/transport/my_trips/#{trip.id}/start"
      expect(response).to have_http_status(:ok)
      expect(trip.reload.status).to eq("in_progress")
    end

    it "carro de até 8 lugares sai com categoria B" do
      trip = trip_for("confirmed", seats: 4)
      davi.transport_driver.update_columns(license_category: "B")
      json_post "/transport/my_trips/#{trip.id}/start"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "FW4: sem sessão → 401" do
    it "lista de passageiros (PDF) e faltas respondem 401 unauthenticated, não 403" do
      trip = trip_for("confirmed")
      get "/transport/trips/#{trip.id}/manifest.pdf"
      expect(response).to have_http_status(:unauthorized)
      get "/transport/no_shows", params: { from: Date.current.iso8601, to: Date.current.iso8601 }
      expect(response).to have_http_status(:unauthorized)
      get "/transport/my_trips"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
