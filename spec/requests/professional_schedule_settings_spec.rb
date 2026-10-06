require "rails_helper"

# Contrato §9: as escritas novas devolvem o objeto puro (o turno, o vínculo).
RSpec.describe "Modelo no turno e tipo padrão do vínculo (API)", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:admin) { staff_with("admin-agenda@cidade.gov.br", "municipal_admin") }
  let(:link) { doctor_link!(create_unit) }
  let(:template) { ScheduleTemplate.create!(name: "Manhã", blocks: [ { "starts" => "09:00", "ends" => "10:00", "kind" => "blocked" } ]) }
  let(:day) { Time.zone.tomorrow.in_time_zone }
  def body = JSON.parse(response.body)

  it "lança com modelo, troca o modelo, define o tipo padrão e a ficha mostra os dois" do
    sign_in_as(admin)
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 8).iso8601,
                                                        ends_at: day.change(hour: 12).iso8601, schedule_template_id: template.id
    expect(response).to have_http_status(:created)
    expect(body["shift"]["schedule_template_id"]).to eq(template.id)
    shift_id = body.dig("shift", "id")

    json_post "/professionals/shifts/#{shift_id}/template", schedule_template_id: nil
    expect(response).to have_http_status(:ok)
    expect(body).to include("id" => shift_id, "schedule_template_id" => nil, "professional_link_id" => link.id)
    expect(body).not_to have_key("shift")

    json_post "/professionals/shifts/#{shift_id}/template", schedule_template_id: SecureRandom.uuid
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_template")

    json_post "/professionals/links/#{link.id}/default_type", appointment_type_key: "retorno"
    expect(response).to have_http_status(:ok)
    expect(body).to include("id" => link.id, "default_appointment_type_key" => "retorno")
    expect(body).not_to have_key("link")

    json_post "/professionals/links/#{link.id}/default_type", appointment_type_key: "consulta_enfermagem"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "type_not_served")

    get "/professionals/#{link.professional_id}"
    expect(body["links"].sole["default_appointment_type_key"]).to eq("retorno")
    get "/professionals/#{link.professional_id}/shifts"
    expect(body["shifts"].sole["schedule_template_id"]).to be_nil
  end

  it "turno com modelo inválido no lançamento é 422; modelo em turno cancelado é 409" do
    sign_in_as(admin)
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 8).iso8601,
                                                        ends_at: day.change(hour: 12).iso8601, schedule_template_id: SecureRandom.uuid
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_template")

    shift = shift!(link, starts_at: day.change(hour: 8))
    shift.update!(cancelled_at: Time.current, cancelled_by_user: admin, cancel_reason: "troca de escala")
    json_post "/professionals/shifts/#{shift.id}/template", schedule_template_id: template.id
    expect(response).to have_http_status(:conflict)
    expect(body).to eq("error" => "already_cancelled")
  end

  it "recepção não mexe (403)" do
    sign_in_as(staff_with("recepcao-agenda@cidade.gov.br", "citizen_verifier"))
    json_post "/professionals/links/#{link.id}/default_type", appointment_type_key: "retorno"
    expect(response).to have_http_status(:forbidden)
    json_post "/professionals/shifts/#{shift!(link, starts_at: day.change(hour: 8)).id}/template", schedule_template_id: nil
    expect(response).to have_http_status(:forbidden)
  end
end
