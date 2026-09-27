require "rails_helper"

RSpec.describe "Professional shifts", type: :request do
  def json = JSON.parse(response.body)

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:doctor) do
    Professional.create!(user: staff_with("medica@cidade.gov.br", "health_professional"), professional_name: "Helena",
                         council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005")
  end
  let(:link) do
    Current.set(city: TEST_CITY_A) do
      Professionals::OpenLink.call(professional: doctor, health_unit_id: create_unit.id, cbo_code: "225125", by: admin)
                             .payload[:link]
    end
  end
  let(:day) { Time.zone.tomorrow.in_time_zone }

  before { sign_in_as(admin) }

  it "lança (sem step-up), lista no intervalo e cancela" do
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 19).iso8601,
                                                        ends_at: (day + 1.day).change(hour: 7).iso8601
    expect(response).to have_http_status(:created)
    shift_id = json.dig("shift", "id")

    get "/professionals/#{doctor.id}/shifts"
    expect(json["shifts"].map { |s| s["id"] }).to eq([ shift_id ])

    json_post "/professionals/shifts/#{shift_id}/cancel", reason: "troca de escala"
    expect(response).to have_http_status(:ok)
    get "/professionals/#{doctor.id}/shifts"
    expect(json["shifts"].sole).to include("cancel_reason" => "troca de escala")
  end

  it "turno noturno iniciado antes do intervalo padrão aparece por sobreposição" do
    old_link = Current.set(city: TEST_CITY_A) do
      ProfessionalLink.create!(professional: doctor, health_unit_id: create_unit.id, cbo_code: "225125",
                               started_at: 2.days.ago.in_time_zone, started_by_user: admin)
    end
    from = Time.zone.today
    overnight = ProfessionalShift.create!(professional_link: old_link, professional_id: doctor.id,
                                          starts_at: 1.day.ago.in_time_zone.change(hour: 19),
                                          ends_at: from.in_time_zone.change(hour: 7), created_by_user: admin)

    get "/professionals/#{doctor.id}/shifts"
    expect(json["shifts"].map { |s| s["id"] }).to eq([ overnight.id ])
  end

  it "sobreposição: 409 shift_overlap com o conflito" do
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 7).iso8601, ends_at: day.change(hour: 13).iso8601
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 12).iso8601, ends_at: day.change(hour: 14).iso8601
    expect(response).to have_http_status(:conflict)
    expect(json).to include("error" => "shift_overlap")
    expect(json["conflict"]).to include("starts_at" => day.change(hour: 7).iso8601)
  end

  it "intervalo inválido ou maior que 62 dias: 422 invalid_range" do
    get "/professionals/#{doctor.id}/shifts", params: { from: "2026-10-01", to: "2026-12-15" }
    expect(json["error"]).to eq("invalid_range")
    get "/professionals/#{doctor.id}/shifts", params: { from: "xx" }
    expect(json["error"]).to eq("invalid_range")
  end

  it "reason não escalar: 422 invalid e o turno permanece sem cancelar" do
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 7).iso8601, ends_at: day.change(hour: 13).iso8601
    id = json.dig("shift", "id")

    json_post "/professionals/shifts/#{id}/cancel", reason: [ "x" ]
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid")
    expect(ProfessionalShift.find(id).cancelled_at).to be_nil
  end

  it "starts_at não escalar: 422 invalid" do
    json_post "/professionals/links/#{link.id}/shifts", starts_at: {}, ends_at: day.change(hour: 13).iso8601
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid")
  end

  it "motivo vazio: 422 reason_required; cancelar duas vezes: 409" do
    json_post "/professionals/links/#{link.id}/shifts", starts_at: day.change(hour: 7).iso8601, ends_at: day.change(hour: 13).iso8601
    id = json.dig("shift", "id")
    json_post "/professionals/shifts/#{id}/cancel", reason: ""
    expect(json["error"]).to eq("reason_required")
    json_post "/professionals/shifts/#{id}/cancel", reason: "troca"
    json_post "/professionals/shifts/#{id}/cancel", reason: "troca"
    expect(response).to have_http_status(:conflict)
  end

  (Membership::ROLES - %w[municipal_admin]).each do |role|
    it "#{role}: 403 nas três rotas" do
      sign_in_as(staff_with("#{role}@cidade.gov.br", role))
      get "/professionals/#{doctor.id}/shifts"
      expect(response).to have_http_status(:forbidden)
      json_post "/professionals/links/#{link.id}/shifts", starts_at: day.iso8601, ends_at: (day + 1.hour).iso8601
      expect(response).to have_http_status(:forbidden)
      json_post "/professionals/shifts/#{SecureRandom.uuid}/cancel", reason: "x"
      expect(response).to have_http_status(:forbidden)
      expect(ProfessionalShift.count).to eq(0)
    end
  end
end
