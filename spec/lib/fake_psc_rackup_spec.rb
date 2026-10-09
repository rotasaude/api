require "rails_helper"
require "rack"

# O serviço fake-psc do compose sobe do config.ru com a AC do diretório dado.
RSpec.describe "lib/fake_psc/config.ru" do
  def build_app(absent: nil)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("SIGNER_DEV_PKI_DIR").and_return(FakePsc::Pki::FIXTURES)
    allow(ENV).to receive(:fetch).with("FAKE_PSC_ABSENT_CPFS", "").and_return(absent.to_s)
    app = Rack::Builder.parse_file(Rails.root.join("lib/fake_psc/config.ru").to_s)
    app.is_a?(Array) ? app.first : app
  end

  def discover(app, cpf)
    body = { client_id: FakePsc::App::CLIENT_ID, client_secret: FakePsc::App::CLIENT_SECRET, user_cpf_cnpj: "CPF", val_cpf_cnpj: cpf }.to_json
    status, _headers, response = app.call(Rack::MockRequest.env_for("/v0/oauth/user-discovery", method: "POST", input: body))
    [ status, JSON.parse(response.join) ]
  end

  it "monta o PSC simulado e responde à localização por CPF" do
    status, json = discover(build_app, SignatureHelpers::DOCTOR_CPF)
    expect(status).to eq(200)
    expect(json["status"]).to eq("S")
  end

  it "FAKE_PSC_ABSENT_CPFS simula profissional sem certificado" do
    _status, json = discover(build_app(absent: "#{SignatureHelpers::DOCTOR_CPF}, 11111111111"), SignatureHelpers::DOCTOR_CPF)
    expect(json["status"]).to eq("N")
  end

  it "a página de autorização diz PSC SIMULADO — desenvolvimento" do
    app = build_app
    query = Rack::Utils.build_query(response_type: "code", client_id: FakePsc::App::CLIENT_ID, code_challenge_method: "S256",
                                    scope: "signature_session", code_challenge: "a" * 43, redirect_uri: "http://localhost/cb",
                                    login_hint: SignatureHelpers::DOCTOR_CPF, state: "s")
    status, _headers, response = app.call(Rack::MockRequest.env_for("/v0/oauth/authorize?#{query}"))
    expect(status).to eq(200)
    expect(response.join).to include("PSC SIMULADO — desenvolvimento")
  end
end
