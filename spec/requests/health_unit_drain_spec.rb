require "rails_helper"

# api#29 (F-09.3): esvaziar unidade pela porta da frente.
RSpec.describe "Esvaziar unidade", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; Rails.cache.clear; link_professional!(doctor, closing) }
  after { Current.reset }

  let(:closing) { create_unit("UBS Fechando") }
  let(:dest) { create_unit("UBS Destino") }
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def body = JSON.parse(response.body)

  def booked!
    a = in_care!(waiting_attendance(citizen, unit: closing, by: reception), by: doctor)
    req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    Appointments::Schedule.call(request: req, scheduled_at: 5.days.from_now.change(hour: 9).iso8601,
                                health_unit_id: closing.id, by: reception).payload.fetch(:appointment)
  end

  it "só o municipal_admin esvazia; depois disso a unidade desativa" do
    booked!
    sign_in_as(reception)
    json_post "/attendance/units/#{closing.id}/drain", target_unit_id: dest.id, reason: "unidade fechada para reforma"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(admin)
    get "/attendance/units/all"
    row = body["units"].find { |u| u["id"] == closing.id }
    expect(row).to include("live_requests_count" => 1, "live_appointments_count" => 1)

    json_post "/attendance/units/#{closing.id}/deactivate"
    expect([ response.status, body["error"] ]).to eq([ 409, "unit_has_open_requests" ])

    json_post "/attendance/units/#{closing.id}/drain", target_unit_id: dest.id, reason: "unidade fechada para reforma"
    expect(response).to have_http_status(:ok)
    expect(body["drain"]).to include("requests_count" => 1, "appointments_count" => 1)

    json_post "/attendance/units/#{closing.id}/deactivate"
    expect(response).to have_http_status(:ok)
  end

  it "destino inválido ou motivo curto: 422 com o código" do
    sign_in_as(admin)
    json_post "/attendance/units/#{closing.id}/drain", target_unit_id: closing.id, reason: "unidade fechada para reforma"
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_target" ])
    json_post "/attendance/units/#{closing.id}/drain", target_unit_id: dest.id, reason: "curto"
    expect([ response.status, body["error"] ]).to eq([ 422, "reason_too_short" ])
  end

  it "o cidadão vê só o pedido novo, na nova unidade, e de onde ele veio" do
    appt = booked!
    HealthUnits::Drain.call(unit: closing, target_unit_id: dest.id, reason: "unidade fechada para reforma", by: admin)
    sign_in_citizen("+5541998765432")
    get "/citizen/appointments", params: { citizen_id: citizen.id }
    items = body["appointments"]
    expect(items.size).to eq(1)
    expect(items.first["request"]).to include("target_unit_name" => "UBS Destino", "moved_from_unit_name" => "UBS Fechando")
    expect(items.first["appointment"]).to include("scheduled_at" => appt.scheduled_at.iso8601, "status" => "scheduled")
  end
end
