require "rails_helper"

RSpec.describe "/professionals/schedule_templates", type: :request do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:admin) { staff_with("admin-modelos@cidade.gov.br", "municipal_admin") }
  let(:blocks) { [ { starts: "09:00", ends: "11:00", kind: "bookable", appointment_type_key: "consulta_medica" } ] }
  def body = JSON.parse(response.body)

  it "lista, cria, edita e pré-visualiza (só admin); objeto puro; detail no 422" do
    sign_in_as(staff_with("recepcao-modelos@cidade.gov.br", "citizen_verifier"))
    get "/professionals/schedule_templates"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(admin)
    json_post "/professionals/schedule_templates", name: "Manhã", fit_in_limit: 3, blocks: blocks
    expect(response).to have_http_status(:created)
    id = body["id"]
    expect(body).to eq("id" => id, "name" => "Manhã", "fit_in_limit" => 3, "active" => true,
                       "blocks" => [ { "starts" => "09:00", "ends" => "11:00", "kind" => "bookable", "appointment_type_key" => "consulta_medica" } ])

    json_post "/professionals/schedule_templates/#{id}", blocks: [ { starts: "09:00", ends: "08:00", kind: "blocked" } ]
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body).to eq("error" => "invalid_blocks", "detail" => "crosses_midnight")

    get "/professionals/schedule_templates"
    expect(body["templates"].map { |t| t["id"] }).to eq([ id ])

    day = Time.zone.today + 3
    json_post "/professionals/schedule_templates/preview",
              blocks: blocks, fit_in_limit: 2,
              sample: { starts_at: day.in_time_zone.change(hour: 8).iso8601, ends_at: day.in_time_zone.change(hour: 12).iso8601, cbo_code: "225125" }
    expect(response).to have_http_status(:ok)
    expect(body["slots"].size).to eq(6)
    expect(ScheduleTemplate.count).to eq(1)
  end

  it "404 para modelo inexistente; 422 invalid na amostra ruim; inactive_type na faixa" do
    type_row!("acupuntura", active: false)
    sign_in_as(admin)
    json_post "/professionals/schedule_templates/#{SecureRandom.uuid}", name: "X"
    expect([ response.status, body ]).to eq([ 404, { "error" => "not_found" } ])
    json_post "/professionals/schedule_templates/nao-e-uuid", name: "X"
    expect(response).to have_http_status(:not_found)

    json_post "/professionals/schedule_templates/preview", blocks: blocks, fit_in_limit: 2, sample: "x"
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid" } ])

    json_post "/professionals/schedule_templates", name: "M",
              blocks: [ { starts: "09:00", ends: "10:00", kind: "bookable", appointment_type_key: "acupuntura" } ]
    expect(body).to eq("error" => "invalid_blocks", "detail" => "inactive_type")
    expect(ScheduleTemplate.count).to eq(0)
  end
end
