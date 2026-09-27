require "rails_helper"

RSpec.describe "Professional links", type: :request do
  def json = JSON.parse(response.body)

  # Abrir/encerrar vínculo exige step-up de MFA; o admin precisa estar
  # inscrito para poder carimbar a janela nos testes (mesmo padrão de
  # spec/requests/setup_grant_role_spec.rb).
  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:unit) { create_unit }
  let(:doctor) do
    Professional.create!(user: staff_with("medica@cidade.gov.br", "health_professional"), professional_name: "Helena",
                         council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005")
  end

  def sign_in_admin!(stepped_up: true)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
  end

  it "abre com step-up: 201 com o vínculo e o título do CBO" do
    sign_in_admin!
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "225125"
    expect(response).to have_http_status(:created)
    expect(json["link"]).to include("unit_name" => unit.name, "cbo_code" => "225125", "cbo_title" => "Médico clínico",
                                    "ended_at" => nil)
  end

  it "sem step-up: 401 mfa_required e nada abre" do
    sign_in_admin!(stepped_up: false)
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "225125"
    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "mfa_required")
    expect(ProfessionalLink.count).to eq(0)
  end

  it "recusas nomeadas: invalid_cbo, council_mismatch, invalid_unit (422) e already_linked (409)" do
    sign_in_admin!
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "999999"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid_cbo")
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "223505"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("council_mismatch")
    json_post "/professionals/#{doctor.id}/links", health_unit_id: SecureRandom.uuid, cbo_code: "225125"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid_unit")
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "225125"
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "225125"
    expect(response).to have_http_status(:conflict)
    expect(json["error"]).to eq("already_linked")
  end

  it "encerra com step-up; sem step-up é 401; segunda vez é 409 already_ended" do
    link = Current.set(city: TEST_CITY_A) do
      Professionals::OpenLink.call(professional: doctor, health_unit_id: unit.id, cbo_code: "225125", by: admin).payload[:link]
    end
    sign_in_admin!(stepped_up: false)
    json_post "/professionals/links/#{link.id}/end"
    expect(response).to have_http_status(:unauthorized)
    expect(link.reload.ended_at).to be_nil

    Session.find_by(user: admin).update!(mfa_verified_at: Time.current)
    json_post "/professionals/links/#{link.id}/end"
    expect(response).to have_http_status(:ok)
    expect(json).to include("cancelled_shift_ids" => [])
    json_post "/professionals/links/#{link.id}/end"
    expect(response).to have_http_status(:conflict)
    expect(json["error"]).to eq("already_ended")
  end

  it "cbo_code não escalar: 422 invalid; nada abre" do
    sign_in_admin!
    json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: [ "x" ]
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "invalid")
    expect(ProfessionalLink.count).to eq(0)
  end

  it "perfil ou vínculo inexistente: 404" do
    sign_in_admin!
    json_post "/professionals/#{SecureRandom.uuid}/links", health_unit_id: unit.id, cbo_code: "225125"
    expect(response).to have_http_status(:not_found)
    json_post "/professionals/links/#{SecureRandom.uuid}/end"
    expect(response).to have_http_status(:not_found)
  end

  (Membership::ROLES - %w[municipal_admin]).each do |role|
    it "#{role}: 403 nas duas rotas, mesmo com step-up" do
      user = staff_with("#{role}@cidade.gov.br", role)
      sign_in_as(user).update!(mfa_verified_at: Time.current)
      json_post "/professionals/#{doctor.id}/links", health_unit_id: unit.id, cbo_code: "225125"
      expect(response).to have_http_status(:forbidden)
      json_post "/professionals/links/#{SecureRandom.uuid}/end"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
