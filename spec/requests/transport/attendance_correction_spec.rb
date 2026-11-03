require "rails_helper"

# Módulo 30, Task 8 (ADR 0048; contrato §5; §14 T18): POST
# /transport/trips/:id/attendance_correction { items, reason } — só a central,
# com step-up; devolve <trip>.
RSpec.describe "Transporte — correção da presença", type: :request do
  let!(:city) { transport_city! }
  let(:trip) { trip!(date: Date.current - 1, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "done") }
  let!(:rider) { passenger!(trip, attendance: "boarded") }
  let(:body) { { items: [ { passenger_id: rider.id, attendance: "no_show" } ], reason: "Paciente não embarcou, conferido com a família" } }

  def correct!(payload = body) = json_post("/transport/trips/#{trip.id}/attendance_correction", payload)

  it "sem step-up → 401 mfa_required; presença intacta" do
    sign_in_as(step_up_enrolled!(dispatcher!))
    correct!
    expect(response).to have_http_status(:unauthorized)
    expect(json_body["error"]).to eq("mfa_required")
    expect(rider.reload.attendance).to eq("boarded")
  end

  it "com step-up corrige e devolve <trip> com a presença nova" do
    stepped_up!(dispatcher!)
    correct!
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => trip.id, "status" => "done")
    expect(json_body["passengers"].find { |p| p["id"] == rider.id }).to include("attendance" => "no_show")
    expect(TransportAttendanceCorrection.where(transport_trip_passenger: rider).count).to eq(1)
  end

  it "motivo curto → 422 com path; viagem desconhecida → 404; motorista → 403" do
    stepped_up!(dispatcher!)
    correct!(body.merge(reason: "curto"))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "reason")
    json_post "/transport/trips/#{SecureRandom.uuid}/attendance_correction", body
    expect(response).to have_http_status(:not_found)
    stepped_up!(driver_user!)
    correct!
    expect(response).to have_http_status(:forbidden)
    expect(rider.reload.attendance).to eq("boarded")
  end
end
