require "rails_helper"

# Spec da API §8/§9: escrita de protocolo numa cidade. Um caminho só
# (CityMutation): escopo do token, tentativa gravada antes, CityWriter abre a
# cidade, o command roda como o mantenedor com o correlation_id da auditoria,
# e o resultado fecha o par. O mantenedor nunca assina.
RSpec.describe "Maintenance protocol mutations", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "pm-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def totp = ROTP::TOTP.new(maintainer.otp_secret).now

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: totp }, headers: browser
    expect(response).to have_http_status(:ok)
  end

  def gql!(query, headers: browser, **variables)
    post "/graphql", params: { query: query, variables: variables.to_json }, headers: headers
  end

  # P1: consulta em método, nunca em constante de topo.
  def save_draft_mutation
    <<~GQL
      mutation($citySlug: String!, $definition: JSON!) {
        saveProtocolDraft(citySlug: $citySlug, definition: $definition) { ok errors { path message } }
      }
    GQL
  end

  def save_draft!(definition, city_slug: city.slug, headers: browser)
    gql!(save_draft_mutation, headers: headers, citySlug: city_slug, definition: definition)
  end

  def payload = json.dig("data", "saveProtocolDraft")

  # Mesmo arranjo de spec/requests/maintenance/city_spec.rb.
  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let!(:archived_city) do
    City.create!(slug: "arquivada-#{SecureRandom.hex(3)}", name: "Cidade Arquivada", uf: "sp",
                status: "archived", schema_version: "0",
                # Nunca discada: cidade não ativa recusa antes de conectar.
                database_url: "postgres://unreachable.invalid/none",
                encryption_key: SecureRandom.hex(32))
  end

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  # Um marcador no conteúdo, para provar que nenhum pedaço da definition vai
  # parar na auditoria de plataforma.
  let(:marker) { "marcador-#{SecureRandom.hex(4)}" }
  let(:definition) do
    protocol_definition_hash.tap { |d| d["steps"].first["prompt"] = marker }
  end

  def audit_events = PlatformEvent.where(name: "maintenance.protocol.draft_saved").order(:created_at)
  def versions = ProtocolDefinition.where(name: "dengue", version: 1)

  before do
    register_city!(TEST_CITY_A)
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    travel_to(1.minute.ago) { login! }
  end

  describe "saveProtocolDraft" do
    it "saves the draft as the maintainer and audits attempt and outcome on the command's correlation id" do
      save_draft!(definition)

      expect(payload).to eq("ok" => true, "errors" => [])
      version = versions.sole
      expect(version.status).to eq("draft")
      expect(version.contributions.map { |c| [ c.actor_kind, c.actor_id ] }).to eq([ [ "maintainer", maintainer.id ] ])

      events = audit_events.to_a
      expect(events.map { |e| e.payload["outcome"] }).to eq(%w[attempted ok])
      correlation_ids = events.map { |e| e.payload["correlation_id"] }.uniq
      expect(correlation_ids.size).to eq(1)
      expect(events.last.payload).to include("city_slug" => city.slug, "protocol_key" => "dengue", "version" => 1,
                                             "changed_fields" => [ "definition" ], "maintainer_id" => maintainer.id,
                                             "module" => "protocol")

      domain_event = DomainEvent.where(name: "protocol.draft_saved").order(:occurred_at).last
      expect(domain_event.payload).to include("actor_kind" => "maintainer", "actor" => maintainer.id,
                                              "correlation_id" => correlation_ids.first)
    end

    it "turns a domain refusal into a user error on definition, audited as rejected, changing nothing" do
      Current.set(city: city) do
        Protocols::SaveDraft.call(definition: protocol_definition_hash, by: Maintenance::MaintainerActor.new(maintainer))
      end
      versions.sole.update!(status: "published")
      contributions_before = ProtocolContribution.count

      save_draft!(definition)

      expect(payload["ok"]).to be(false)
      expect(payload["errors"].map { |e| e["path"] }).to eq([ "definition" ])
      expect(audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted rejected])
      expect(versions.sole.status).to eq("published")
      expect(versions.sole.definition.to_json).not_to include(marker)
      expect(ProtocolContribution.count).to eq(contributions_before)
    end

    it "refuses a city that does not exist, on citySlug, audited as rejected, without connecting" do
      expect(CityConnection).not_to receive(:with)

      save_draft!(definition, city_slug: "cidade-que-nao-existe")

      expect(payload["ok"]).to be(false)
      expect(payload["errors"].map { |e| e["path"] }).to eq([ "citySlug" ])
      expect(audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted rejected])
    end

    it "refuses a city that is not active, on citySlug, audited as rejected, without connecting" do
      expect(CityConnection).not_to receive(:with)

      save_draft!(definition, city_slug: archived_city.slug)

      expect(payload["ok"]).to be(false)
      expect(payload["errors"].first).to include("path" => "citySlug")
      expect(payload["errors"].first["message"]).to include("archived")
      expect(audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted rejected])
    end

    it "does not run the command when the attempt cannot be recorded" do
      allow(MaintenanceAudit).to receive(:record).and_call_original
      allow(MaintenanceAudit).to receive(:record)
        .with("maintenance.protocol.draft_saved", hash_including(outcome: "attempted"))
        .and_raise(ActiveRecord::StatementInvalid, "platform down")
      expect(Protocols::SaveDraft).not_to receive(:call)

      save_draft!(definition)

      expect(payload).to be_nil
      expect(json["errors"].first.dig("extensions", "code")).to eq("CITY_WRITE_FAILED")
      expect(versions).to be_empty
      expect(audit_events).to be_empty
    end

    it "answers CITY_UNREACHABLE when the city does not answer, audited as error" do
      allow(Maintenance::CityWriter).to receive(:call)
        .and_raise(Maintenance::CityWriter::Unreachable, "PG::ConnectionBad: connection to [redigido] failed")

      save_draft!(definition)

      expect(payload).to be_nil
      expect(json["errors"].first.dig("extensions", "code")).to eq("CITY_UNREACHABLE")
      expect(audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted error])
    end

    it "answers CITY_WRITE_FAILED for any other failure, publishing only the class, audited as error" do
      allow(Protocols::SaveDraft).to receive(:call).and_raise(ArgumentError, "telefone +55 41 99999-0000")

      save_draft!(definition)

      expect(payload).to be_nil
      expect(json["errors"].first.dig("extensions", "code")).to eq("CITY_WRITE_FAILED")
      expect(json["errors"].first["message"]).to include("ArgumentError")
      expect(response.body).not_to include("99999-0000")
      expect(audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted error])
      expect(audit_events.map { |e| e.payload.to_json }.join).not_to include("99999-0000")
    end

    it "refuses a service token before executing, changing nothing" do
      _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                                               city_slugs: [], expires_at: 5.days.from_now)
      expect(Protocols::SaveDraft).not_to receive(:call)

      save_draft!(definition, headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" })

      expect(json["errors"].first.dig("extensions", "code")).to eq("TOKEN_SCOPE_REFUSED")
      expect(versions).to be_empty
      expect(audit_events).to be_empty
    end

    # A identidade do protocolo vai para a auditoria (protocol_key/version) —
    # então ela é recusada ANTES de auditar se não for o que diz ser: a
    # auditoria não grava estrutura arbitrária vinda do cliente.
    it "refuses a definition whose name or version is not a bounded identifier, before auditing" do
      protocols_before = ProtocolDefinition.count
      [ protocol_definition_hash.merge("name" => { "x" => marker }),
        protocol_definition_hash.merge("name" => "Dengue #{marker}"),
        protocol_definition_hash.merge("name" => "d#{'e' * 63}"),
        protocol_definition_hash.merge("name" => "1dengue"),
        protocol_definition_hash.merge("version" => "1"),
        protocol_definition_hash.merge("version" => [ 1 ]),
        protocol_definition_hash.merge("version" => 0),
        protocol_definition_hash.merge("version" => -1),
        protocol_definition_hash.merge("version" => 10_001) ].each do |bad|
        save_draft!(bad)

        expect(payload["ok"]).to be(false)
        expect(payload["errors"].map { |e| e["path"] }).to eq([ "definition" ])
      end

      expect(PlatformEvent.where("name LIKE ?", "maintenance.protocol.%")).to be_empty
      expect(ProtocolDefinition.count).to eq(protocols_before)
    end

    # O JSON escalar aceita qualquer valor JSON; só objeto é definição.
    it "refuses a definition that is not a JSON object as a user error, before auditing" do
      [ "texto #{marker}", 42, [ 1, 2 ], true ].each do |bad|
        save_draft!(bad)

        expect(response).to have_http_status(:ok)
        expect(payload["ok"]).to be(false)
        expect(payload["errors"].map { |e| e["path"] }).to eq([ "definition" ])
      end

      expect(PlatformEvent.where("name LIKE ?", "maintenance.protocol.%")).to be_empty
    end

    # O slug vai para platform_events (imutável): só entra se tiver a forma de
    # um slug de City. Qualquer outra coisa é erro de usuário, sem auditoria.
    it "refuses a citySlug that is not a city slug, before auditing and without connecting" do
      expect(CityConnection).not_to receive(:with)

      [ "Cidade #{marker}", "a" * 64, "a" * 5_000, "x", "-curitiba", "curitiba-", "curi_tiba" ].each do |bad|
        save_draft!(definition, city_slug: bad)

        expect(payload["ok"]).to be(false)
        expect(payload["errors"].map { |e| e["path"] }).to eq([ "citySlug" ])
      end

      expect(PlatformEvent.where("name LIKE ?", "maintenance.protocol.%")).to be_empty
    end

    it "never puts the definition, or any piece of it, in the platform audit" do
      save_draft!(definition)
      save_draft!(definition, city_slug: archived_city.slug)

      events = PlatformEvent.where("name LIKE ?", "maintenance.protocol.%")
      expect(events.count).to eq(4)
      events.each do |event|
        expect(event.payload.keys).not_to include("definition", "steps", "scoring", "start_step_id")
        expect(event.payload.to_json).not_to include(marker)
      end
    end
  end

  # Task 3: submitProtocolForReview e publishProtocol. O mantenedor nunca
  # assina (D6) — as assinaturas de publicação vêm de revisores da própria
  # cidade, arranjadas direto no banco (make_reviewer!/sign!), como a spec de
  # assinaturas já faz.
  describe "submitProtocolForReview and publishProtocol" do
    def submit_mutation
      <<~GQL
        mutation($citySlug: String!, $name: String!, $version: Int!) {
          submitProtocolForReview(citySlug: $citySlug, name: $name, version: $version) { ok errors { path message } }
        }
      GQL
    end

    def submit!(name: "dengue", version: 1, city_slug: city.slug, headers: browser)
      gql!(submit_mutation, headers: headers, citySlug: city_slug, name: name, version: version)
    end

    def submit_payload = json.dig("data", "submitProtocolForReview")

    def publish_mutation
      <<~GQL
        mutation($citySlug: String!, $name: String!, $version: Int!, $code: String!) {
          publishProtocol(citySlug: $citySlug, name: $name, version: $version, code: $code) { ok errors { path message } }
        }
      GQL
    end

    def publish!(name: "dengue", version: 1, code:, city_slug: city.slug, headers: browser)
      gql!(publish_mutation, headers: headers, citySlug: city_slug, name: name, version: version, code: code)
    end

    def publish_payload = json.dig("data", "publishProtocol")

    def publish_audit_events = PlatformEvent.where(name: "maintenance.protocol.published").order(:created_at)

    # Arranjo direto no banco da cidade (já aberto pelo harness — ver
    # spec/support/city_test_databases.rb), do mesmo jeito que a spec de
    # assinaturas assina: nenhum dos dois signatários pode ser o mantenedor,
    # porque não existe mutation de assinatura para ele chamar.
    def sign_two_reviewers!(protocol, purpose: "publication")
      Array.new(2) { make_reviewer! }.each { |reviewer| sign!(protocol, purpose: purpose, by: reviewer) }
    end

    it "submits a draft for review, is signed by two city reviewers, and is published with step-up" do
      save_draft!(definition)
      version = versions.sole

      submit!
      expect(submit_payload).to eq("ok" => true, "errors" => [])
      expect(version.reload.status).to eq("in_review")

      reviewers = Array.new(2) { make_reviewer! }
      reviewers.each { |reviewer| sign!(version, purpose: "publication", by: reviewer) }

      publish!(code: totp)

      expect(publish_payload).to eq("ok" => true, "errors" => [])
      expect(version.reload.status).to eq("published")

      publish_audit = publish_audit_events.last
      expect(publish_audit.payload["outcome"]).to eq("ok")

      domain_event = DomainEvent.where(name: "protocol.published").order(:occurred_at).last
      expect(domain_event.payload).to include("actor_kind" => "maintainer", "actor" => maintainer.id,
                                              "correlation_id" => publish_audit.payload["correlation_id"])
      expect(domain_event.payload["signers"]).to match_array(reviewers.map(&:id))
    end

    it "refuses to publish without the city's two publication signatures, leaving the version in_review" do
      save_draft!(definition)
      submit!
      version = versions.sole

      publish!(code: totp)

      expect(publish_payload["ok"]).to be(false)
      expect(publish_payload["errors"].map { |e| e["path"] }).to eq([ "version" ])
      expect(publish_payload["errors"].first["message"])
        .to match(/faltam 2 assinaturas de publicação; revisores elegíveis na cidade: \d+/)
      expect(publish_audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted rejected])
      expect(version.reload.status).to eq("in_review")
    end

    it "never counts the maintainer as a signer: one city signature still leaves one missing" do
      save_draft!(definition)
      submit!
      version = versions.sole
      sign!(version, purpose: "publication", by: make_reviewer!)

      publish!(code: totp)

      expect(publish_payload["ok"]).to be(false)
      expect(publish_payload["errors"].first["message"]).to include("falta 1 assinatura de publicação")
      expect(version.reload.status).to eq("in_review")
    end

    it "requires the step-up code to publish, refusing a wrong one on code without changing anything" do
      save_draft!(definition)
      submit!
      version = versions.sole
      sign_two_reviewers!(version)

      publish!(code: "000000")

      expect(publish_payload["ok"]).to be(false)
      expect(publish_payload["errors"].map { |e| e["path"] }).to eq([ "code" ])
      expect(publish_audit_events.map { |e| e.payload["outcome"] }).to eq(%w[attempted rejected])
      expect(version.reload.status).to eq("in_review")
    end

    it "asks for no step-up code to submit a draft for review" do
      save_draft!(definition)

      submit!

      expect(submit_payload).to eq("ok" => true, "errors" => [])
    end

    it "refuses to submit a version that is not a draft, on version" do
      save_draft!(definition)
      submit!
      version = versions.sole
      expect(version.status).to eq("in_review")

      submit!

      expect(submit_payload["ok"]).to be(false)
      expect(submit_payload["errors"].map { |e| e["path"] }).to eq([ "version" ])
      expect(submit_payload["errors"].first["message"]).to include("rascunho")
      expect(version.reload.status).to eq("in_review")
    end
  end
end
