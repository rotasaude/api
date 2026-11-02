# spec/lib/fake_rnds_spec.rb
require "rails_helper"
require_relative "../../lib/fake_rnds/app"

# A RNDS simulada: token, aceite com Location, recusa por marcador, timeout e
# quedas por `failures`.
RSpec.describe FakeRnds::App do
  let(:now) { Time.utc(2026, 11, 3, 12) }
  let(:app) { described_class.new(clock: -> { now }, timeout_delay: 0) }
  let(:mock) { Rack::MockRequest.new(app) }

  def bundle(lot: "L123") = { "resourceType" => "Bundle", "entry" => [ { "resource" => { "resourceType" => "Immunization", "lotNumber" => lot } } ] }

  def token = JSON.parse(mock.get("/api/token").body).fetch("access_token")

  def post_bundle(body: bundle, token: self.token, cns: "700000000000005")
    headers = { "CONTENT_TYPE" => "application/fhir+json", "HTTP_X_AUTHORIZATION_SERVER" => "Bearer #{token}" }
    headers["HTTP_AUTHORIZATION"] = cns if cns
    mock.post("/api/fhir/r4/Bundle", headers.merge(input: JSON.generate(body)))
  end

  it "emite token e aceita o Bundle com 201 e Location" do
    expect(JSON.parse(mock.get("/api/token").body)).to include("token_type" => "jwt", "expires_in" => 1800, "access_token" => be_a(String))
    response = post_bundle
    expect(response.status).to eq(201)
    expect(response.location).to end_with("/api/fhir/r4/Bundle/#{app.accepted.last[:id]}")
    expect(app.log.last).to eq([ "POST", "/api/fhir/r4/Bundle", { "authorization" => "700000000000005", "x-authorization-server" => "Bearer #{app.issued_tokens.last}" } ])
  end

  it "recusa por marcador com OperationOutcome; sem token, token vencido e sem CNS" do
    refused = post_bundle(body: bundle(lot: "RECUSA"))
    expect(refused.status).to eq(422)
    expect(JSON.parse(refused.body)).to include("resourceType" => "OperationOutcome", "issue" => [ include("diagnostics" => "Lote inválido para o CPF 12345678901") ])
    expect(app.accepted).to be_empty
    expect(post_bundle(token: "qualquer").status).to eq(401)
    old = token
    app.clock = -> { now + 1801 }
    expect(post_bundle(token: old).status).to eq(401)
    expect(post_bundle(cns: nil, token: token).status).to eq(422)
    expect(post_bundle(body: { "resourceType" => "Patient" }).status).to eq(400)
  end

  it "TIMEOUT segura a resposta e estoura; failures simulam queda" do
    expect { post_bundle(body: bundle(lot: "TIMEOUT")) }.to raise_error(Net::ReadTimeout)
    live = token
    app.failures.push(503, :refused)
    expect(post_bundle(token: live).status).to eq(503)
    expect { post_bundle(token: live) }.to raise_error(Errno::ECONNREFUSED)
    expect(post_bundle(token: live).status).to eq(201)
  end

  it "o config.ru sobe fora de produção e a rota desconhecida dá 404" do
    expect(Rack::Builder.parse_file(Rails.root.join("lib/fake_rnds/config.ru").to_s)).to be_present
    expect(mock.get("/api/outra").status).to eq(404)
  end
end
