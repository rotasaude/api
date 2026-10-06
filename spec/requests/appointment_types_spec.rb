require "rails_helper"

RSpec.describe "/professionals/appointment_types", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:admin) { staff_with("admin-tipos@cidade.gov.br", "municipal_admin") }
  def body = JSON.parse(response.body)

  it "lista para quem lê (admin, recepção, profissional, autoria, revisão) e recusa quem não lê" do
    %w[municipal_admin citizen_verifier health_professional protocol_author protocol_reviewer].each do |role|
      sign_in_as(staff_with("#{role}-#{SecureRandom.hex(2)}@cidade.gov.br", role))
      get "/professionals/appointment_types"
      expect(response).to have_http_status(:ok), role
      expect(body["types"].first).to eq("key" => "consulta_medica", "name" => "Consulta médica", "duration_minutes" => 20,
                                        "cbo_prefixes" => ["2251", "2252", "2253"], "active" => true, "origin" => "platform")
    end
    sign_in_as(staff_with("viewer-#{SecureRandom.hex(2)}@cidade.gov.br", "viewer"))
    get "/professionals/appointment_types"
    expect(response).to have_http_status(:forbidden)
  end

  it "cria e ajusta (só admin); devolve o tipo puro; erros com o código do contrato" do
    sign_in_as(staff_with("recepcao-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    json_post "/professionals/appointment_types", key: "acupuntura", name: "Acupuntura", duration_minutes: 30, cbo_prefixes: ["2251"]
    expect(response).to have_http_status(:forbidden)

    sign_in_as(admin)
    json_post "/professionals/appointment_types", key: "acupuntura", name: "Acupuntura", duration_minutes: 30, cbo_prefixes: ["2251"]
    expect(response).to have_http_status(:created)
    expect(body).to include("key" => "acupuntura", "origin" => "city")

    json_post "/professionals/appointment_types/acupuntura", active: false
    expect(response).to have_http_status(:ok)
    expect(body["active"]).to be(false)

    json_post "/professionals/appointment_types/consulta_medica", cbo_prefixes: ["2251"]
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "platform_type_locked")

    json_post "/professionals/appointment_types", key: "acupuntura", name: "Outra", duration_minutes: 30, cbo_prefixes: ["2251"]
    expect(body).to eq("error" => "key_taken")

    json_post "/professionals/appointment_types/acupuntura", name: ""
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_name")

    json_post "/professionals/appointment_types/fantasma", active: false
    expect(response).to have_http_status(:not_found)
  end
end
