require "rails_helper"

# Módulo 30, Task 6 (ADR 0048; contrato §4, §14 T18): faltas por paciente e a
# lista de passageiros em PDF. Sem dado clínico, sem trilha.
RSpec.describe "Transporte — faltas e lista de passageiros", type: :request do
  let!(:city) { transport_city! }
  let(:van) { vehicle!(seats: 15) }
  let(:driver) { driver_user!.transport_driver }
  let(:patient) { transport_patient! }

  # Viagem em andamento com a presença marcada; `finish` a leva a done.
  def trip_with(patient, attendance, date:, status: "done", **over)
    trip = trip!(date: date, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "in_progress")
    passenger!(trip, patient: patient, **over).update!(attendance: attendance)
    trip.update!(status: status) unless status == "in_progress"
    trip
  end

  describe "GET /transport/no_shows" do
    before { sign_in_as(dispatcher!) }

    it "duas faltas do mesmo paciente em viagens done → count 2 com as duas datas; in_progress e presentes não contam" do
      d1 = Date.current - 3
      d2 = Date.current - 1
      trip_with(patient, "no_show", date: d1)
      trip_with(patient, "no_show", date: d2)
      trip_with(patient, "no_show", date: Date.current, status: "in_progress")
      trip_with(patient, "boarded", date: Date.current - 2)
      other = transport_patient!
      trip_with(other, "no_show", date: d2)

      get "/transport/no_shows", params: { from: (Date.current - 10).iso8601, to: Date.current.iso8601 }

      expect(response).to have_http_status(:ok)
      items = json_body.fetch("items")
      expect(items.size).to eq(2)
      first = items.first
      expect(first).to eq("patient" => { "id" => patient.id, "display_name" => patient.display_name }, "count" => 2,
                          "dates" => [ d1.iso8601, d2.iso8601 ])
      expect(items.last).to include("count" => 1)
      expect(response.body).not_to include("Ponta Grossa", "destination")
    end

    it "limite: 366 dias passa, 367 é recusado; falta de passageiro retirado não conta" do
      today = Time.zone.today
      removed_trip = trip_with(patient, "no_show", date: today - 1)
      removed_trip.transport_trip_passengers.first.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Desistiu")
      get "/transport/no_shows", params: { from: (today - 365).iso8601, to: today.iso8601 }
      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).to eq([])
      get "/transport/no_shows", params: { from: (today - 366).iso8601, to: today.iso8601 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["path"]).to eq("to")
    end

    it "respeita o período; fora dele ou com intervalo maior que 366 dias → invalid_request" do
      trip_with(patient, "no_show", date: Date.current - 5)
      get "/transport/no_shows", params: { from: (Date.current - 2).iso8601, to: Date.current.iso8601 }
      expect(json_body["items"]).to eq([])
      get "/transport/no_shows", params: { from: (Date.current - 400).iso8601, to: Date.current.iso8601 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("invalid_request")
      get "/transport/no_shows", params: { from: "ontem", to: Date.current.iso8601 }
      expect(response).to have_http_status(:unprocessable_entity)
      get "/transport/no_shows", params: { to: Date.current.iso8601 }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  it "comissão, admin e motorista → 403" do
    trip = trip!
    [ committee!, transport_admin!, driver_user! ].each do |user|
      sign_in_as(user)
      get "/transport/no_shows", params: { from: Time.zone.today.iso8601, to: Time.zone.today.iso8601 }
      expect(response).to have_http_status(:forbidden)
      get "/transport/trips/#{trip.id}/manifest.pdf"
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "sem sessão não lê nem a lista nem as faltas" do
    get "/transport/no_shows", params: { from: Time.zone.today.iso8601, to: Time.zone.today.iso8601 }
    first = response.status
    get "/transport/trips/#{trip!.id}/manifest.pdf"
    expect([ first, response.status ]).to all(satisfy { |code| [ 401, 403 ].include?(code) })
    expect(response.body).not_to start_with("%PDF")
  end

  describe "GET /transport/trips/:id/manifest.pdf" do
    before { sign_in_as(dispatcher!) }

    it "devolve application/pdf inline, sem cache, e não publica evento" do
      trip = trip!(vehicle: van, driver: driver)
      passenger!(trip, patient: patient)
      expect { get "/transport/trips/#{trip.id}/manifest.pdf" }.not_to change(DomainEvent, :count)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to start_with("inline")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.body).to start_with("%PDF")
    end

    it "viagem desconhecida → 404" do
      get "/transport/trips/#{SecureRandom.uuid}/manifest.pdf"
      expect(response).to have_http_status(:not_found)
    end
  end
end
