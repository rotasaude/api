require "rails_helper"

RSpec.describe "Citizen appointments", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def body = JSON.parse(response.body)

  def appointment_for(person, delta: 3.days)
    a = in_care!(waiting_attendance(person, unit: unit, by: reception), by: doctor)
    req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    Appointments::Schedule.call(request: req, scheduled_at: delta.from_now.iso8601, health_unit_id: unit.id,
                                by: reception).payload.fetch(:appointment)
  end

  it "lista, confirma e cancela os próprios" do
    appt = appointment_for(citizen)
    sign_in_citizen("+5541998765432")

    get "/citizen/appointments", params: { citizen_id: citizen.id }
    item = body["appointments"].first
    expect(item["request"]).to include("kind" => "return", "target_unit_name" => unit.name, "status" => "scheduled")
    expect(item["appointment"]).to include("id" => appt.id, "status" => "scheduled", "check_in_available" => false)
    expect(item["appointment"]["confirmation_deadline_at"]).to be_present

    json_post "/citizen/appointments/#{appt.id}/confirm"
    expect(response).to have_http_status(:ok)
    json_post "/citizen/appointments/#{appt.id}/cancel", reason: "curto"
    expect(response).to have_http_status(:unprocessable_entity)
    json_post "/citizen/appointments/#{appt.id}/cancel", reason: "vou viajar nessa semana"
    expect(response).to have_http_status(:ok)
  end

  it "horário de outro celular com o mesmo CPF: 404 nos dois sentidos" do
    other = Citizen.create!(cpf: citizen.cpf, phone: "+5541911112222")
    mine = appointment_for(citizen)
    theirs = appointment_for(other)
    sign_in_citizen("+5541998765432")
    json_post "/citizen/appointments/#{theirs.id}/confirm"
    expect(response).to have_http_status(:not_found)
    get "/citizen/appointments", params: { citizen_id: other.id }
    expect(response).to have_http_status(:not_found)

    sign_in_citizen("+5541911112222")
    json_post "/citizen/appointments/#{mine.id}/cancel", reason: "vou viajar nessa semana"
    expect(response).to have_http_status(:not_found)
  end

  it "código de check-in só no dia do horário confirmado" do
    travel_to(Time.zone.parse("2026-10-02 09:00")) do
      appt = appointment_for(citizen, delta: 2.hours) # nasce confirmado, hoje
      sign_in_citizen("+5541998765432")
      get "/citizen/appointments", params: { citizen_id: citizen.id }
      expect(body["appointments"].first["appointment"]["check_in_available"]).to be(true)
      json_post "/citizen/appointments/#{appt.id}/check_in_code"
      expect(response).to have_http_status(:created)
      expect(body["code"]).to match(/\A\d{6}\z/)
    end
  end

  it "triagens mostram chamada e tipo do pedido" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil, by: doctor)
    sign_in_citizen("+5541998765432")
    get "/citizen/triages", params: { citizen_id: citizen.id }
    att = body["triages"].first["attendance"]
    expect(att).to include("status" => "closed", "outcome" => "return", "request_kind" => "return")
    expect(att["called_at"]).to be_present
  end
end
