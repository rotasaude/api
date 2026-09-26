require "rails_helper"

RSpec.describe "Appointment requests", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def body = JSON.parse(response.body)

  def returned_attendance(priority: 5)
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    a.triage.update_columns(priority: priority)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: "reavaliar",
                            by: doctor).payload.fetch(:appointment_request)
  end

  it "lista pedidos abertos da unidade, marca horário e aparece na agenda do dia" do
    req = returned_attendance
    sign_in_as(reception)

    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"].first).to include("id" => req.id, "kind" => "return", "cpf_masked" => citizen.cpf_masked,
                                              "priority" => 5, "note" => "reavaliar", "reopened_reason" => nil)

    at = 3.days.from_now.change(hour: 14, min: 30)
    json_post "/attendance/requests/#{req.id}/appointments", scheduled_at: at.iso8601, health_unit_id: unit.id
    expect(response).to have_http_status(:created)
    expect(body["appointment"]).to include("status" => "scheduled")

    get "/attendance/units/#{unit.id}/requests"
    expect(body["requests"]).to eq([])

    get "/attendance/units/#{unit.id}/agenda", params: { date: at.to_date.iso8601 }
    expect(body["appointments"].first).to include("cpf_masked" => citizen.cpf_masked, "kind" => "return",
                                                  "status" => "scheduled")
  end

  it "profissional não marca horário (403)" do
    req = returned_attendance
    sign_in_as(doctor)
    json_post "/attendance/requests/#{req.id}/appointments", scheduled_at: 3.days.from_now.iso8601,
                                                             health_unit_id: unit.id
    expect(response).to have_http_status(:forbidden)
  end

  it "encerra pedido com justificativa" do
    req = returned_attendance
    sign_in_as(reception)
    json_post "/attendance/requests/#{req.id}/dismiss", reason: "cidadão mudou de cidade", health_unit_id: unit.id
    expect(response).to have_http_status(:ok)
    json_post "/attendance/requests/#{req.id}/dismiss", reason: "curto", health_unit_id: unit.id
    expect(response).to have_http_status(:conflict)
  end
end
