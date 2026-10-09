require "rails_helper"

# Contrato §8: PSC reais do ambiente (credencial presente + última checagem) e
# estado do signer. Nunca segredo, URL ou CPF; nenhuma cidade é aberta.
RSpec.describe "Maintenance: assinatura digital", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "sig-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
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
    allow(Signatures::Providers).to receive(:credentials).and_return(
      "vidaas" => { "client_id" => "id", "client_secret" => "SEGREDO-PSC", "base_url" => "https://psc.test" }
    )
    SignatureProviderCheck.where(provider: "vidaas").delete_all
    Signatures::Providers.record_check!("vidaas", ok: true)
    login!
  end

  it "lists the 5 real providers with environment-level credential and last check; no secret, no simulated" do
    expect(Maintenance::CityReader).not_to receive(:call)
    gql!("{ signatureProviders { key configured lastCheckAt lastCheckOk } }")
    rows = json.dig("data", "signatureProviders")
    expect(rows.map { |row| row["key"] }).to eq(%w[vidaas birdid safeid neoid remoteid])
    expect(rows.first).to include("configured" => true, "lastCheckOk" => true)
    expect(rows.first["lastCheckAt"]).to be_present
    expect(rows.second).to eq("key" => "birdid", "configured" => false, "lastCheckAt" => nil, "lastCheckOk" => nil)
    expect(response.body).not_to include("SEGREDO-PSC", "psc.test", "simulated")
  end

  it "signer status: reachable with version and CRL; unreachable never fails the query" do
    stub_signer!
    gql!("{ signerStatus { reachable version crlUpdatedAt } }")
    expect(json.dig("data", "signerStatus")).to include("reachable" => true, "version" => "fake-1")
    allow(Signatures::Signer.client).to receive(:health).and_raise(Signatures::Signer::Unavailable)
    gql!("{ signerStatus { reachable version crlUpdatedAt } }")
    expect(json.dig("data", "signerStatus")).to eq("reachable" => false, "version" => nil, "crlUpdatedAt" => nil)
    allow(Signatures::Signer.client).to receive(:health).and_raise(NoMethodError, "bug nosso")
    expect(Rails.error).to receive(:report).with(an_instance_of(NoMethodError), anything)
    gql!("{ signerStatus { reachable version crlUpdatedAt } }")
    expect(json.dig("data", "signerStatus")).to eq("reachable" => false, "version" => nil, "crlUpdatedAt" => nil)
  end

  it "signer status against the real compose signer", :signer do
    gql!("{ signerStatus { reachable version crlUpdatedAt } }")
    status = json.dig("data", "signerStatus")
    expect(status["reachable"]).to be(true)
    expect(status["version"]).to be_present
  end
end
