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

  describe "Bundle RIRA (26c): cadeia por Bundle.identifier.value" do
    let(:profile) { Regulation::RiraProfile.current }
    let(:system_url) { "#{profile.identifiers[:requester_prefix]}12345" }

    def rira(value: "mira-1", relates_to: nil)
      composition = { "resourceType" => "Composition", "meta" => { "profile" => [ profile.profiles[:composition] ] },
                      "type" => { "coding" => [ { "system" => profile.code_systems[:document_type], "code" => "RA" } ] } }
      composition["relatesTo"] = [ { "code" => "replaces", "targetReference" => { "reference" => "Composition/#{relates_to}" } } ] if relates_to
      { "resourceType" => "Bundle", "type" => "document", "identifier" => { "system" => system_url, "value" => value },
        "entry" => [ { "fullUrl" => "urn:uuid:1", "resource" => composition } ] }
    end

    def id_of(response) = response.location.split("/").last

    def chain(value: "mira-1", token: self.token, system: system_url)
      query = Rack::Utils.build_query("system" => system, "value" => value, "docType" => "RIRA")
      response = mock.get("/api/identifier?#{query}", "HTTP_X_AUTHORIZATION_SERVER" => "Bearer #{token}", "HTTP_AUTHORIZATION" => "700000000000005")
      [ response, response.status == 200 ? JSON.parse(response.body) : nil ]
    end

    def delete(id, token: self.token)
      mock.delete("/api/fhir/r4/Bundle/#{id}", "HTTP_X_AUTHORIZATION_SERVER" => "Bearer #{token}", "HTTP_AUTHORIZATION" => "700000000000005")
    end

    it "reconhece o Bundle pelos perfis do YAML do RIRA" do
      expect(profile.profiles[:composition]).to end_with(FakeRnds::App::RIRA_PROFILE_SUFFIX)
    end

    it "Bundle RIRA aceito com location" do
      response = post_bundle(body: rira)
      expect(response.status).to eq(201)
      expect(response.location).to end_with("/api/fhir/r4/Bundle/#{app.accepted.last[:id]}")
    end

    it "substituição aceita e a cadeia mostra o anterior entered-in-error" do
      first = id_of(post_bundle(body: rira))
      second = id_of(post_bundle(body: rira(relates_to: first)))
      _, docs = chain
      expect(docs).to contain_exactly(
        include("id" => first, "status" => "entered-in-error", "relatesTo" => nil, "date" => now.iso8601),
        include("id" => second, "status" => "final", "relatesTo" => first, "date" => now.iso8601)
      )
    end

    it "substituir o mesmo de novo -> 422 com EDS-MSG009" do
      first = id_of(post_bundle(body: rira))
      post_bundle(body: rira(relates_to: first))
      again = post_bundle(body: rira(relates_to: first))
      expect(again.status).to eq(422)
      expect(JSON.parse(again.body).dig("issue", 0, "diagnostics")).to eq("(EDS-MSG009) O documento #{first} já foi substituído.")
    end

    it "DELETE de final -> 204; de entered-in-error -> 422 EHR-ERR825; id desconhecido -> 404" do
      id = id_of(post_bundle(body: rira))
      expect(delete(id).status).to eq(204)
      expect(chain.last).to contain_exactly(include("id" => id, "status" => "entered-in-error"))
      refused = delete(id)
      expect(refused.status).to eq(422)
      expect(JSON.parse(refused.body).dig("issue", 0, "diagnostics")).to include("EHR-ERR825")
      expect(delete(SecureRandom.uuid).status).to eq(404)
      expect(delete(id, token: "qualquer").status).to eq(401)
    end

    it "GET /api/identifier devolve a cadeia do identificador; vazio sem documento; 401 sem token" do
      expect(chain.last).to eq([])
      id = id_of(post_bundle(body: rira))
      post_bundle(body: rira(value: "outro"))
      _, docs = chain
      expect(docs).to match([ { "id" => id, "cns" => be_a(String), "date" => now.iso8601, "relatesTo" => nil, "status" => "final" } ].map { |h| a_hash_including(h) })
      expect(docs.size).to eq(1)
      expect(chain(token: "qualquer").first.status).to eq(401)
    end

    it "RECUSA no identificador -> 422 EHR-ERR999 e nada gravado" do
      response = post_bundle(body: rira(value: "RECUSA-1"))
      expect(response.status).to eq(422)
      expect(JSON.parse(response.body).dig("issue", 0, "diagnostics")).to include("EHR-ERR999")
      expect(chain(value: "RECUSA-1").last).to eq([])
    end

    it "TIMEOUT grava e levanta" do
      expect { post_bundle(body: rira(value: "TIMEOUT-1")) }.to raise_error(Net::ReadTimeout)
      expect(chain(value: "TIMEOUT-1").last).to contain_exactly(include("status" => "final"))
    end

    it "DUPLICADO grava dois finais sem relação e levanta (sem 201)" do
      expect { post_bundle(body: rira(value: "DUPLICADO-1")) }.to raise_error(Net::ReadTimeout)
      docs = chain(value: "DUPLICADO-1").last
      expect(docs.size).to eq(2)
      expect(docs).to all(include("status" => "final", "relatesTo" => nil))
      expect(docs.map { |d| d["id"] }.uniq.size).to eq(2)
      older, newer = docs.sort_by { |d| Time.iso8601(d["date"]) }
      expect(Time.iso8601(newer["date"])).to be > Time.iso8601(older["date"])
      expect(newer["date"]).to eq((now + 1).iso8601)
      expect(newer["id"]).to eq(docs.last["id"]) # o segundo gravado é o mais novo
    end

    it "DUPLICADO só age no primeiro POST: o segundo, com o relatesTo, segue a cadeia normal" do
      expect { post_bundle(body: rira(value: "DUPLICADO-2")) }.to raise_error(Net::ReadTimeout)
      keep, drop = chain(value: "DUPLICADO-2").last.map { |d| d["id"] }
      expect(delete(drop).status).to eq(204)
      expect(post_bundle(body: rira(value: "DUPLICADO-2", relates_to: keep)).status).to eq(201)
    end

    it "o cancelamento da vacina não vira substituição no fake" do
      cancel = bundle
      cancel["entry"] << { "resource" => { "resourceType" => "Composition", "relatesTo" => [ { "code" => "replaces", "targetIdentifier" => { "value" => "x" } } ] } }
      first = post_bundle(body: cancel)
      second = post_bundle(body: cancel)
      expect([ first.status, second.status ]).to eq([ 201, 201 ])
      expect(chain(value: "x").last).to eq([])
    end

    it "o lotNumber RECUSA da vacina segue igual" do
      expect(post_bundle(body: bundle(lot: "RECUSA")).status).to eq(422)
    end
  end

  it "o config.ru sobe fora de produção e a rota desconhecida dá 404" do
    expect(Rack::Builder.parse_file(Rails.root.join("lib/fake_rnds/config.ru").to_s)).to be_present
    expect(mock.get("/api/outra").status).to eq(404)
  end
end
