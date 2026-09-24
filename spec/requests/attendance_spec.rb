require "rails_helper"

RSpec.describe "Attendance", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:admin) { user_with("admin@cidade.gov.br", "municipal_admin") }
  let(:viewer) { user_with("leitura@cidade.gov.br", "viewer") }
  def body = JSON.parse(response.body)

  def user_with(email, role)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: role, granted_at: Time.current)
    end
  end

  it "lookup e validação pelo atendente" do
    code = issue_code_for(citizen)
    sign_in_as(verifier)
    json_post "/attendance/lookup", cpf: "529.982.247-25", code: code
    expect(response).to have_http_status(:ok)
    expect(body["citizen"]).to include("cpf_masked" => "***.982.247-**", "phone_masked" => "(**) *****-5432",
                                       "verification_level" => "declared")
    expect(body.to_s).not_to include("998765432")

    json_post "/attendance/verifications", cpf: "529.982.247-25", code: code, document_checked: true
    expect(response).to have_http_status(:created)
    expect(citizen.reload).to be_verification_level_verified
  end

  it "lookup sem código não devolve dado do cadastro" do
    issue_code_for(citizen)
    sign_in_as(verifier)
    json_post "/attendance/lookup", cpf: "529.982.247-25"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body.keys).to eq(["error"])
  end

  it "sem a caixa 'conferi o documento': 422" do
    sign_in_as(verifier)
    json_post "/attendance/verifications", cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: false
    expect(body["error"]).to eq("document_check_required")
  end

  it "par já verificado: 409 com a data" do
    code = issue_code_for(citizen)
    sign_in_as(verifier)
    json_post "/attendance/verifications", cpf: citizen.cpf, code: code, document_checked: true
    CitizenVerificationCode.create!(citizen: citizen, code_digest: CitizenVerificationCode.digest(citizen.id, "123456"),
                                    expires_at: 10.minutes.from_now)
    json_post "/attendance/lookup", cpf: citizen.cpf, code: "123456"
    expect(response).to have_http_status(:conflict)
    expect(body).to include("error" => "already_verified", "verified_at" => be_present)
  end

  it "viewer não usa o atendimento: 403" do
    sign_in_as(viewer)
    json_post "/attendance/lookup", cpf: citizen.cpf, code: issue_code_for(citizen)
    expect(response).to have_http_status(:forbidden)
  end

  it "admin lista e desfaz; o próprio validador não desfaz" do
    sign_in_as(verifier)
    json_post "/attendance/verifications", cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: true
    id = body.dig("verification", "id")

    json_post "/attendance/verifications/#{id}/revoke", reason: "documento de outra pessoa"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(admin)
    get "/attendance/verifications", params: { cpf: "529.982.247-25" }
    expect(body["verifications"].sole).to include("verified_by" => "atendente@cidade.gov.br", "active" => true)

    json_post "/attendance/verifications/#{id}/revoke", reason: "curto"
    expect(body["error"]).to eq("reason_too_short")
    json_post "/attendance/verifications/#{id}/revoke", reason: "documento de outra pessoa"
    expect(response).to have_http_status(:ok)
    expect(citizen.reload).to be_verification_level_declared
  end

  it "admin que também é atendente não desfaz a própria validação: 403 own_verification" do
    Membership.create!(user: admin, role: "citizen_verifier", granted_at: Time.current)
    sign_in_as(admin)
    json_post "/attendance/verifications", cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: true
    json_post "/attendance/verifications/#{body.dig('verification', 'id')}/revoke", reason: "documento de outra pessoa"
    expect(response).to have_http_status(:forbidden)
    expect(body["error"]).to eq("own_verification")
  end

  it "o histórico por CPF é só do admin" do
    sign_in_as(verifier)
    get "/attendance/verifications", params: { cpf: citizen.cpf }
    expect(response).to have_http_status(:forbidden)
  end

  it "escrita sem JSON é recusada" do
    sign_in_as(verifier)
    post "/attendance/lookup", params: { cpf: citizen.cpf, code: "123456" }
    expect(response).to have_http_status(:unsupported_media_type)
  end
end
