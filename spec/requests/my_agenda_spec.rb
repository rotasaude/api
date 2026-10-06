require "rails_helper"

RSpec.describe "GET /professionals/me/agenda", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:doctor) { link.professional.user }
  let(:day) { Time.zone.today + 1 }
  def body = JSON.parse(response.body)

  it "dias do intervalo, turnos com unidade e faixas, horários sem a justificativa do encaixe" do
    shift = shift!(link, starts_at: day.in_time_zone.change(hour: 8))
    fit = appointment_row!(triage_request!(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: unit), shift,
                           starts_at: shift.starts_at, kind: "fit_in", reason: "gestante com dor")
    sign_in_as(doctor)
    get "/professionals/me/agenda", params: { from: day.iso8601, to: (day + 1).iso8601 }
    expect(response).to have_http_status(:ok)
    expect(body["days"].map { |d| d["date"] }).to eq([ day.iso8601, (day + 1).iso8601 ])
    first = body["days"].first["shifts"].sole
    expect(first).to include("shift_id" => shift.id, "unit" => { "id" => unit.id, "name" => unit.name }, "cancelled_at" => nil)
    expect(first["blocks"]).to eq([ { "starts" => "08:00", "ends" => "12:00", "kind" => "bookable",
                                      "appointment_type_key" => "consulta_medica", "appointment_type_name" => "Consulta médica" } ])
    expect(first["appointments"].sole).to include("id" => fit.id, "fit_in" => true)
    expect(first["appointments"].sole).not_to have_key("fit_in_reason")
    expect(body["days"].last["shifts"]).to eq([])
  end

  it "sem cadastro profissional 404 no_profile; mais de 7 dias 422; recepção 403" do
    sign_in_as(staff_with("medica-sem-cadastro@cidade.gov.br", "health_professional"))
    get "/professionals/me/agenda"
    expect(response).to have_http_status(:not_found)
    expect(body).to eq("error" => "no_profile")

    sign_in_as(doctor)
    get "/professionals/me/agenda", params: { from: day.iso8601, to: (day + 7).iso8601 }
    expect(body).to eq("error" => "invalid_range")

    sign_in_as(staff_with("recepcao-minha@cidade.gov.br", "citizen_verifier"))
    get "/professionals/me/agenda"
    expect(response).to have_http_status(:forbidden)
  end
end
