require "rails_helper"

RSpec.describe "Citizen OTP and session", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { OtpSender::Test.reset!; Rails.cache.clear }
  after { travel_back }

  let(:phone) { "(41) 99876-5432" }

  def last_code = OtpSender::Test.deliveries.last[:code]

  it "manda o código e abre a sessão com cookie httpOnly" do
    json_post "/citizen/otp", phone: phone
    expect(response).to have_http_status(:accepted)
    expect(JSON.parse(response.body)).to eq("status" => "sent", "resend_after" => 60)

    json_post "/citizen/session", phone: phone, code: last_code
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to eq("phone_masked" => "(**) *****-5432")
    expect(response.headers["Set-Cookie"]).to match(/citizen_session=.*httponly/i)

    get "/citizen/session"
    expect(response).to have_http_status(:ok)
  end

  it "responde igual para telefone novo e telefone já cadastrado" do
    Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    json_post "/citizen/otp", phone: phone
    known = [response.status, response.body]
    json_post "/citizen/otp", phone: "(41) 91111-2222"
    expect([response.status, response.body]).to eq(known)
  end

  it "recusa telefone que não é celular brasileiro" do
    json_post "/citizen/otp", phone: "(41) 3333-4444"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("invalid_phone")
  end

  it "reenvio antes de 60 s responde 429 too_soon" do
    json_post "/citizen/otp", phone: phone
    json_post "/citizen/otp", phone: phone
    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(response.body)["error"]).to eq("too_soon")
  end

  it "sem provedor de SMS, 503 e o desafio não conta no limite" do
    Rails.configuration.x.otp_sender = nil
    json_post "/citizen/otp", phone: phone
    expect(response).to have_http_status(:service_unavailable)
    expect(OtpChallenge.count).to eq(0)
  ensure
    Rails.configuration.x.otp_sender = :test
  end

  it "código errado e código vencido" do
    json_post "/citizen/otp", phone: phone
    json_post "/citizen/session", phone: phone, code: (last_code == "000000" ? "111111" : "000000")
    expect(JSON.parse(response.body)["error"]).to eq("invalid_code")
    travel 11.minutes
    json_post "/citizen/session", phone: phone, code: last_code
    expect(JSON.parse(response.body)["error"]).to eq("code_expired")
  end

  it "sair revoga a sessão" do
    sign_in_citizen
    delete "/citizen/session", headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:no_content)
    get "/citizen/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "sem cookie, 401" do
    get "/citizen/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "escrita autenticada sem JSON é recusada" do
    sign_in_citizen
    post "/citizen/otp", params: { phone: phone }
    expect(response).to have_http_status(:unsupported_media_type)
  end

  it "cidade com banco atrasado responde 503" do
    allow(CitySchema).to receive(:behind?).and_return(true)
    json_post "/citizen/otp", phone: phone
    expect(response).to have_http_status(:service_unavailable)
  end

  it "o cookie de servidor da cidade não abre sessão de cidadão" do
    user = User.create!(email_address: "servidor@cidade.gov.br", password: "senha-segura-123")
    sign_in_as(user)
    get "/citizen/session"
    expect(response).to have_http_status(:unauthorized)
  end
end
