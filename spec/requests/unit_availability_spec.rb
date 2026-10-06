require "rails_helper"

RSpec.describe "GET /attendance/units/:id/availability", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:day) { Time.zone.today + 2 }
  def body = JSON.parse(response.body)

  it "vagas com o nome do profissional e os dias legacy, para a recepção" do
    shift = shift!(link, starts_at: day.in_time_zone.change(hour: 8), ends_at: day.in_time_zone.change(hour: 8, min: 40))
    sign_in_as(staff_with("recepcao-vagas@cidade.gov.br", "citizen_verifier"))
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica", from: day.iso8601, to: (day + 1).iso8601 }
    expect(response).to have_http_status(:ok)
    expect(body["slots"]).to eq([
      { "professional_id" => link.professional_id, "professional_name" => link.professional.professional_name,
        "shift_id" => shift.id, "starts_at" => shift.starts_at.iso8601, "ends_at" => (shift.starts_at + 20.minutes).iso8601 },
      { "professional_id" => link.professional_id, "professional_name" => link.professional.professional_name,
        "shift_id" => shift.id, "starts_at" => (shift.starts_at + 20.minutes).iso8601, "ends_at" => shift.ends_at.iso8601 }
    ])
    expect(body["legacy_days"]).to eq([ (day + 1).iso8601 ])

    get "/attendance/units/#{unit.id}/availability", params: { type: "fantasma", from: day.iso8601, to: day.iso8601 }
    expect(response).to have_http_status(:ok)
    expect(body).to eq("slots" => [], "legacy_days" => [])

    AppointmentType.find_by!(key: "consulta_medica").update!(active: false)
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica", from: day.iso8601, to: (day + 1).iso8601 }
    expect(response).to have_http_status(:ok)
    expect(body).to eq("slots" => [], "legacy_days" => [])
  end

  it "sem from/to: hoje + 6 dias, inclusivo" do
    sign_in_as(staff_with("recepcao-vagas@cidade.gov.br", "citizen_verifier"))
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica" }
    today = Time.zone.today
    expect(body["legacy_days"]).to eq((today..today + 6).map(&:iso8601))
  end

  it "intervalo inválido ou maior que 14 dias: 422 invalid_range; profissional sem papel de recepção: 403" do
    sign_in_as(staff_with("recepcao-vagas@cidade.gov.br", "citizen_verifier"))
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica", from: day.iso8601, to: (day + 13).iso8601 }
    expect(response).to have_http_status(:ok)
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica", from: day.iso8601, to: (day + 14).iso8601 }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_range")
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica", from: "ontem" }
    expect(body).to eq("error" => "invalid_range")

    sign_in_as(staff_with("medica-vagas@cidade.gov.br", "health_professional"))
    get "/attendance/units/#{unit.id}/availability", params: { type: "consulta_medica" }
    expect(response).to have_http_status(:forbidden)
  end
end
