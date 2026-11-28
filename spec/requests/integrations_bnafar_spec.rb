# spec/requests/integrations_bnafar_spec.rb
require "rails_helper"
require "webmock/rspec"

# Módulo 27b, Task 8 (Q9): a credencial `bnafar` por ambiente, o teste de
# conexão contra o simulado e o GET /integrations com a do ambiente em uso.
RSpec.describe "Integrações da cidade: bnafar", type: :request do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:fake) { fake_bnafar! }
  def json = JSON.parse(response.body)

  def sign_in_admin!(stepped_up: true)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
  end

  def put_bnafar(body) = put("/integrations/credentials/bnafar", params: body, as: :json)

  before do
    Bnafar::Client.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_BNAFAR_URL").and_return(FAKE_BNAFAR_BASE)
    fake
  end

  it "PUT com step-up grava cifrado; sem step-up → 401 mfa_required" do
    sign_in_admin!(stepped_up: false)
    put_bnafar(username: "rota", password: "senha-bnafar-secreta")
    expect([ response.status, json["error"] ]).to eq([ 401, "mfa_required" ])

    sign_in_admin!
    put_bnafar(username: "rota", password: "senha-bnafar-secreta")
    expect(response).to have_http_status(:ok)
    expect(json).to include("kind" => "bnafar", "set" => true, "environment" => "production", "set_by" => "admin@cidade.gov.br")
    credential = IntegrationCredential.find_by!(kind: "bnafar", environment: "production")
    expect(credential.password).to eq("senha-bnafar-secreta")
    expect(DomainEvent.where(name: "integration_credential.changed").map(&:payload))
      .to eq([ { "kind" => "bnafar", "environment" => "production", "user_id" => admin.id } ])
  end

  it "resposta, log e eventos sem usuário nem senha" do
    sign_in_admin!
    sink = ActiveSupport::Logger.new(logs = StringIO.new)
    Rails.logger.broadcast_to(sink)
    put_bnafar(username: "usuario-bnafar-x", password: "senha-bnafar-secreta")
    expect(response.body).not_to include("senha-bnafar-secreta")
    expect(response.body).not_to include("usuario-bnafar-x")
    expect(logs.string).not_to include("senha-bnafar-secreta")
    expect(logs.string).not_to include("usuario-bnafar-x")
    expect(DomainEvent.all.map(&:payload).to_s).not_to include("senha-bnafar-secreta")
    expect(PlatformEvent.all.map(&:payload).to_s).not_to include("usuario-bnafar-x")
  ensure
    Rails.logger.stop_broadcasting_to(sink) if sink
  end

  it "campo vazio e ambiente desconhecido → 422" do
    sign_in_admin!
    put_bnafar(username: "rota", password: " ")
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_credential" } ])
    put_bnafar(username: "rota", password: "x", environment: "sandbox")
    expect([ response.status, json ]).to eq([ 422, { "error" => "invalid_environment" } ])
  end

  it "homologation em test passa; a credencial de produção segue ao lado (uma linha por ambiente)" do
    sign_in_admin!
    put_bnafar(username: "rota", password: "senha-producao", environment: "production")
    put_bnafar(username: "rota-hom", password: "senha-homologacao", environment: "homologation")
    expect(response).to have_http_status(:ok)
    expect(json).to include("environment" => "homologation")
    expect(IntegrationCredential.where(kind: "bnafar").pluck(:environment)).to contain_exactly("homologation", "production")
    put_bnafar(username: "rota-hom", password: "outra", environment: "homologation")
    expect(IntegrationCredential.where(kind: "bnafar").count).to eq(2)
    expect(IntegrationCredential.find_by!(kind: "bnafar", environment: "production").password).to eq("senha-producao")
  end

  it "com Rails.env production (stub), homologation → 422 environment_not_allowed e nada gravado" do
    sign_in_admin!
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    put_bnafar(username: "rota-hom", password: "senha-homologacao", environment: "homologation")
    expect([ response.status, json ]).to eq([ 422, { "error" => "environment_not_allowed" } ])
    expect(IntegrationCredential.where(kind: "bnafar")).to be_empty
    expect(PlatformEvent.where(name: "bnafar.credential_set")).to be_empty
  end

  it "environment só vale para bnafar: nas outras é ignorado (ledi continua production)" do
    sign_in_admin!
    put("/integrations/credentials/ledi", params: { username: "rota", password: "senha", environment: "homologation" }, as: :json)
    expect(response).to have_http_status(:ok)
    expect(json["environment"]).to eq("production")
    expect(IntegrationCredential.find_by!(kind: "ledi").environment).to eq("production")
  end

  it "auditoria só com city_id e environment" do
    sign_in_admin!
    put_bnafar(username: "rota", password: "senha-bnafar-secreta")
    event = PlatformEvent.where(name: "bnafar.credential_set").last
    expect(event.payload).to eq("city_id" => city.id, "environment" => "production")
  end

  it "GET traz uma só bnafar, a do ambiente em uso, e os outros itens com environment production" do
    sign_in_admin!
    IntegrationCredential.create!(kind: "bnafar", environment: "homologation", secret: { "username" => "u", "password" => "p" },
                                  set_by_user: admin, set_at: Time.current)
    get "/integrations"
    kinds = json["credentials"].map { |c| c["kind"] }
    expect(kinds).to eq(%w[ledi cadsus rnds bnafar rnds_regulation])
    bnafar = json["credentials"].find { |c| c["kind"] == "bnafar" }
    expect(bnafar).to include("set" => false, "environment" => "production")
    expect(json["credentials"].reject { |c| c["kind"] == "bnafar" }.map { |c| c["environment"] }.uniq).to eq([ "production" ])

    allow(Bnafar::Environment).to receive(:current).and_return("homologation")
    get "/integrations"
    bnafar = json["credentials"].find { |c| c["kind"] == "bnafar" }
    expect(bnafar).to include("set" => true, "environment" => "homologation")
  end

  describe "check" do
    before do
      sign_in_admin!
      put_bnafar(username: "rota", password: "senha-bnafar-secreta")
      Platform::Features.set!(city: city, key: "bnafar_mock", enabled: true, maintainer: ledi_maintainer!)
    end

    it "simulado: token emitido → ok" do
      post "/integrations/credentials/bnafar/check", as: :json
      expect(json).to include("last_check_status" => "ok", "last_check_message" => "Token do SI-BNAFAR emitido", "environment" => "production")
      expect(fake.log.map(&:first)).to eq(%w[POST])
      expect(response.body).not_to include("senha-bnafar-secreta")
    end

    it "senha recusada → unauthorized, e o interruptor perde o utilizável (credential_unauthorized:bnafar)" do
      fake.failures.push(401)
      post "/integrations/credentials/bnafar/check", as: :json
      expect(json).to include("last_check_status" => "unauthorized", "last_check_message" => "O SI-BNAFAR recusou usuário ou senha")
      state = Platform::Features.city_state(city)
      expect(state[:credentials]["bnafar"]).to eq("unauthorized")
      CityProfile.current&.update!(ibge_code: "4106902") || CityProfile.create!(name: "Cidade", uf: "PR", ibge_code: "4106902")
      expect(Platform::Features.missing(city, "bnafar")).to eq(%w[credential_unauthorized:bnafar])
    end

    it "queda → unreachable" do
      fake.failures.push(503)
      post "/integrations/credentials/bnafar/check", as: :json
      expect(json).to include("last_check_status" => "unreachable", "last_check_message" => "SI-BNAFAR inalcançável")
    end

    it "sem URL da plataforma (simulado desligado) → error" do
      Platform::Features.set!(city: city, key: "bnafar_mock", enabled: false, maintainer: ledi_maintainer!)
      post "/integrations/credentials/bnafar/check", as: :json
      expect(json).to include("last_check_status" => "error", "last_check_message" => "SI-BNAFAR não configurado pela plataforma")
    end

    it "sem credencial no ambiente em uso → 409 credential_missing" do
      IntegrationCredential.where(kind: "bnafar").delete_all
      post "/integrations/credentials/bnafar/check", as: :json
      expect([ response.status, json ]).to eq([ 409, { "error" => "credential_missing" } ])
    end

    it "kind desconhecido nunca roda o teste de outro kind" do
      expect(Cadsus::Client).not_to receive(:for)
      post "/integrations/credentials/sncr/check", as: :json
      expect([ response.status, json ]).to eq([ 422, { "error" => "unknown_kind" } ])
    end
  end
end
