# spec/requests/integrations_spec.rb
require "rails_helper"
require "webmock/rspec"

# ADR 0028 (spec 2026-10-05 §3.3; contratos §5.1): o municipal_admin cadastra,
# troca (step-up) e testa credenciais. Nenhuma resposta, evento ou log traz o
# segredo.
RSpec.describe "Integrações da cidade", type: :request do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:login_url) { "https://pec.cidade.gov.br/api/recebimento/login" }
  def json = JSON.parse(response.body)

  def sign_in_admin!(stepped_up: true)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
  end

  def put_credential(kind, body) = put("/integrations/credentials/#{kind}", params: body, as: :json)

  it "GET mostra estado sem segredo, com o que falta por interruptor" do
    city.update!(record_mode: "integrated")
    CityProfile.create!(name: "Cidade", uf: "PR", ibge_code: "4106902")
    sign_in_admin!
    get "/integrations"
    expect(json).to include("record_mode" => "integrated", "pec_url_set" => false, "ibge_code_set" => true)
    expect(json["credentials"]).to eq([
      { "kind" => "ledi", "set" => false, "set_at" => nil, "set_by" => nil, "last_check_at" => nil,
        "last_check_status" => nil, "last_check_message" => nil },
      { "kind" => "cadsus", "set" => false, "set_at" => nil, "set_by" => nil, "last_check_at" => nil,
        "last_check_status" => nil, "last_check_message" => nil }
    ])
    expect(json["features"].first).to eq("key" => "ledi_export", "enabled" => false, "usable" => false,
                                         "missing" => %w[pec_url_missing credential_missing:ledi])
  end

  it "PUT exige step-up, grava cifrado, publica evento só com ids e devolve o item sem segredo" do
    sign_in_admin!(stepped_up: false)
    put_credential("ledi", username: "rota", password: "senha-secreta")
    expect([ response.status, json["error"] ]).to eq([ 401, "mfa_required" ])

    sign_in_admin!
    logs = StringIO.new
    sink = ActiveSupport::Logger.new(logs)
    Rails.logger.broadcast_to(sink)
    put_credential("ledi", username: "rota", password: "senha-secreta")
    expect(response).to have_http_status(:ok)
    expect(json).to include("kind" => "ledi", "set" => true, "set_by" => "admin@cidade.gov.br", "last_check_status" => nil)
    expect(response.body).not_to include("senha-secreta")
    expect(logs.string).not_to include("senha-secreta")
    expect(IntegrationCredential.find_by!(kind: "ledi").password).to eq("senha-secreta")
    expect(DomainEvent.where(name: "integration_credential.changed").map(&:payload))
      .to eq([ { "kind" => "ledi", "user_id" => admin.id } ])
  ensure
    Rails.logger.stop_broadcasting_to(sink) if sink
  end

  it "PUT recusa campo vazio e kind desconhecido; só municipal_admin" do
    sign_in_admin!
    put_credential("ledi", username: "rota", password: " ")
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_credential" } ])
    put_credential("rnds", username: "rota", password: "x")
    expect([ response.status, json ]).to eq([ 422, { "error" => "unknown_kind" } ])
    sign_in_as(staff_with("recepcao@cidade.gov.br", "citizen_verifier")).update!(mfa_verified_at: Time.current)
    get "/integrations"
    expect([ response.status, json ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "check sem credencial: 409 credential_missing" do
    sign_in_admin!
    post "/integrations/credentials/ledi/check", as: :json
    expect([ response.status, json ]).to eq([ 409, { "error" => "credential_missing" } ])
  end

  it "check LEDI: login aceito → ok; recusado → unauthorized e o interruptor passa a faltar" do
    city.update!(pec_url: "https://pec.cidade.gov.br")
    sign_in_admin!
    put_credential("ledi", username: "rota", password: "senha-secreta")
    stub_request(:post, login_url).to_return(status: 200, headers: { "Set-Cookie" => "JSESSIONID=x1; Path=/" })
    post "/integrations/credentials/ledi/check", as: :json
    expect(json).to include("last_check_status" => "ok", "last_check_message" => "Login no PEC aceito")

    stub_request(:post, login_url).to_return(status: 401)
    post "/integrations/credentials/ledi/check", as: :json
    expect(json["last_check_status"]).to eq("unauthorized")
    get "/integrations"
    expect(json["features"].first["missing"]).to include("credential_unauthorized:ledi")
  end

  # Review Focus 2: PEC lento e 200 sem cookie.
  it "check LEDI: PEC lento → unreachable; 200 sem cookie → error; mensagens sem segredo" do
    city.update!(pec_url: "https://pec.cidade.gov.br")
    sign_in_admin!
    put_credential("ledi", username: "rota", password: "senha-secreta")
    stub_request(:post, login_url).to_timeout
    post "/integrations/credentials/ledi/check", as: :json
    expect(json).to include("last_check_status" => "unreachable", "last_check_message" => "PEC inalcançável")
    stub_request(:post, login_url).to_return(status: 200, body: "<html>senha-secreta</html>")
    post "/integrations/credentials/ledi/check", as: :json
    expect(json).to include("last_check_status" => "error", "last_check_message" => "O PEC respondeu 200 sem sessão")
    expect(response.body).not_to include("senha-secreta")
    expect(IntegrationCredential.find_by!(kind: "ledi").password).to eq("senha-secreta")
  end

  it "check LEDI: erros de rede não mapeados e URL inválida viram unreachable/error sem vazar" do
    city.update!(pec_url: "https://pec.cidade.gov.br")
    sign_in_admin!
    put_credential("ledi", username: "rota", password: "senha-secreta")
    [ Net::WriteTimeout, Errno::EPIPE, Errno::ENETUNREACH, Net::ProtocolError ].each do |error|
      stub_request(:post, login_url).to_raise(error)
      post "/integrations/credentials/ledi/check", as: :json
      expect(json).to include("last_check_status" => "unreachable", "last_check_message" => "PEC inalcançável")
      expect(response.body).not_to include("pec.cidade.gov.br")
    end
    allow(Platform::Features).to receive(:settings).and_return(record_mode: "integrated", pec_url: "http://exemplo com/x")
    post "/integrations/credentials/ledi/check", as: :json
    expect(json).to include("last_check_status" => "error", "last_check_message" => "Endereço do PEC inválido")
    expect(response.body).not_to include("exemplo")
  end

  it "check LEDI sem endereço do PEC: error com a explicação" do
    sign_in_admin!
    put_credential("ledi", username: "rota", password: "senha-secreta")
    post "/integrations/credentials/ledi/check", as: :json
    expect(json).to include("last_check_status" => "error",
                            "last_check_message" => "Endereço do PEC não definido pelo operador")
  end

  it "check CADSUS (simulado): ok; usuário recusado → unauthorized" do
    sign_in_admin!
    put_credential("cadsus", username: "rota", password: "x")
    post "/integrations/credentials/cadsus/check", as: :json
    expect(json["last_check_status"]).to eq("ok")
    put_credential("cadsus", username: Cadsus::Simulated::REFUSED_USERNAME, password: "x")
    post "/integrations/credentials/cadsus/check", as: :json
    expect(json["last_check_status"]).to eq("unauthorized")
  end
end
