require "rails_helper"

RSpec.describe "Check-ins", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:viewer) { user_with("leitura@cidade.gov.br", "viewer") }
  let(:unit) { create_unit }
  def body = JSON.parse(response.body)

  def user_with(email, role)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: role, granted_at: Time.current)
    end
  end

  def check_in_code_for(triage)
    Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
  end

  it "lookup com código de check-in: 200 sem celular em claro" do
    triage = completed_web_triage_for(citizen)
    code = check_in_code_for(triage)
    sign_in_as(verifier)

    json_post "/attendance/check_ins/lookup", cpf: "529.982.247-25", code: code
    expect(response).to have_http_status(:ok)
    expect(body["citizen"]).to include("cpf_masked" => "***.982.247-**", "phone_masked" => "(**) *****-5432",
                                       "verification_level" => "declared")
    expect(body["triage"]).to include("id" => triage.id, "protocol_name" => triage.protocol_name)
    expect(body.to_s).not_to include("998765432")
  end

  it "lookup com código de validação: 422 invalid_code" do
    completed_web_triage_for(citizen)
    code = Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
    sign_in_as(verifier)

    json_post "/attendance/check_ins/lookup", cpf: citizen.cpf, code: code
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_code")
  end

  it "check-in: 201, depois 409 already_checked_in com unit_name e checked_in_at" do
    triage = completed_web_triage_for(citizen)
    code = check_in_code_for(triage)
    sign_in_as(verifier)

    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: unit.id
    expect(response).to have_http_status(:created)
    expect(body["attendance"]).to include("triage_id" => triage.id, "health_unit_id" => unit.id,
                                          "unit_name" => unit.name, "status" => "waiting",
                                          "check_in_method" => "code")
    expect(body["verified"]).to be(false)

    CitizenVerificationCode.create!(citizen: citizen, purpose: "check_in", triage: triage,
                                    code_digest: CitizenVerificationCode.digest(citizen.id, "123456"),
                                    expires_at: 10.minutes.from_now)
    json_post "/attendance/check_ins/lookup", cpf: citizen.cpf, code: "123456"
    expect(response).to have_http_status(:conflict)
    expect(body["error"]).to eq("already_checked_in")
    expect(body["unit_name"]).to eq(unit.name)
    expect(body["checked_in_at"]).to be_present
  end

  it "check-in de cidadão declarado com document_checked: true valida o cadastro" do
    triage = completed_web_triage_for(citizen)
    code = check_in_code_for(triage)
    sign_in_as(verifier)

    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: true
    expect(response).to have_http_status(:created)
    expect(body["verified"]).to be(true)
    expect(citizen.reload).to be_verification_level_verified
  end

  it "exceção: search lista só triagens elegíveis" do
    fresh = completed_web_triage_for(citizen)
    old_citizen = Citizen.create!(cpf: "52998224725", phone: "+5541933334444")
    completed_web_triage_for(old_citizen, completed_at: 4.days.ago)
    sign_in_as(verifier)

    json_post "/attendance/check_ins/search", cpf: citizen.cpf
    expect(response).to have_http_status(:ok)
    expect(body["triages"].map { |t| t["id"] }).to eq([ fresh.id ])
  end

  it "search publica attendance.exception_searched sem CPF, com by_user_id e result_count" do
    fresh = completed_web_triage_for(citizen)
    sign_in_as(verifier)

    json_post "/attendance/check_ins/search", cpf: citizen.cpf
    expect(response).to have_http_status(:ok)

    events = DomainEvent.where(name: "attendance.exception_searched")
    expect(events.count).to eq(1)
    event = events.sole
    expect(event.payload.keys).to contain_exactly("by_user_id", "result_count")
    expect(event.payload["by_user_id"]).to eq(verifier.id)
    expect(event.payload["result_count"]).to eq([ fresh.id ].size)
    expect(event.payload.to_s).not_to match(/\d{11}/)
  end

  it "exceção com motivo: 201 e check_in_method cpf_exception" do
    triage = completed_web_triage_for(citizen)
    sign_in_as(verifier)

    json_post "/attendance/check_ins/exception", cpf: citizen.cpf, triage_id: triage.id, health_unit_id: unit.id,
                                                 reason: "cidadão sem celular"
    expect(response).to have_http_status(:created)
    expect(body["attendance"]).to include("triage_id" => triage.id, "check_in_method" => "cpf_exception")
    expect(citizen.reload).to be_verification_level_declared
  end

  it "viewer: 403" do
    triage = completed_web_triage_for(citizen)
    code = check_in_code_for(triage)
    sign_in_as(viewer)

    json_post "/attendance/check_ins/lookup", cpf: citizen.cpf, code: code
    expect(response).to have_http_status(:forbidden)
  end

  it "escrita sem JSON: 415" do
    sign_in_as(verifier)
    post "/attendance/check_ins", params: { cpf: citizen.cpf, code: "123456", health_unit_id: unit.id }
    expect(response).to have_http_status(:unsupported_media_type)
  end
end
