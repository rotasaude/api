require "rails_helper"

# Contrato §8: o maintenance vê se o SNCR está configurado no ambiente, se a
# última conversa real deu certo e se o simulado existe aqui. Nunca URL, CNPJ
# ou segredo; nenhuma cidade é aberta; token de serviço não alcança.
RSpec.describe "Maintenance: SNCR", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "sncr-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    expect(response).to have_http_status(:ok)
  end

  def gql!(query) = post("/graphql", params: { query: query, variables: "{}" }, headers: browser)

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    allow(ENV).to receive(:[]).with("FAKE_SNCR_URL").and_return(ControlledPrescriptionHelpers::FAKE_SNCR_BASE)
    allow(Sncr::Config).to receive(:credentials)
      .and_return("base_url" => "https://api-gateway.prd.apps.anvisa.gov.br/api-sncr/api/v1",
                  "auth_url" => "https://sncr-api.apps.anvisa.gov.br/api/v1", "maintainer_cnpj" => "11222333000181")
    SncrCheck.where(target: "real").delete_all
    SncrCheck.record!("real", ok: true)
    login!
  end

  it "configurado, alcançável, simulado disponível; sem URL nem CNPJ; nenhuma cidade aberta" do
    expect(Maintenance::CityReader).not_to receive(:call)
    gql!("{ sncrStatus { configured reachable lastCheckAt simulatedAvailable } }")
    expect(json.dig("data", "sncrStatus")).to include("configured" => true, "reachable" => true, "simulatedAvailable" => true,
                                                      "lastCheckAt" => be_present)
    expect(response.body).not_to include("anvisa", "11222333000181")
  end

  it "sem credencial nem conversa: falso, sem erro" do
    allow(Sncr::Config).to receive(:credentials).and_return({})
    SncrCheck.where(target: "real").delete_all
    gql!("{ sncrStatus { configured reachable lastCheckAt } }")
    expect(json.dig("data", "sncrStatus")).to eq("configured" => false, "reachable" => false, "lastCheckAt" => nil)
  end
end
