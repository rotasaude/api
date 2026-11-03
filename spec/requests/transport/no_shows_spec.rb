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

  it "comissão → 403" do
    sign_in_as(committee!)
    get "/transport/no_shows", params: { from: Date.current.iso8601, to: Date.current.iso8601 }
    expect(response).to have_http_status(:forbidden)
    trip = trip!
    get "/transport/trips/#{trip.id}/manifest.pdf"
    expect(response).to have_http_status(:forbidden)
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
