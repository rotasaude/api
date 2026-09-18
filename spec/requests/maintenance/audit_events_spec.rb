require "rails_helper"

# Spec §9: a auditoria é lida por PESSOA, filtrada, com teto. O payload guarda
# id (Ruling R18); o login é resolvido na leitura, juntando com maintainers.
RSpec.describe "Maintenance audit events", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "ae-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let!(:other) { Maintainer.create!(email_address: "ae2-#{SecureRandom.hex(3)}@rotasaude.app") }

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def totp = ROTP::TOTP.new(maintainer.otp_secret).now

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: totp }, headers: browser
    expect(response).to have_http_status(:ok)
  end

  QUERY = <<~GQL
    query($since: ISO8601DateTime, $until: ISO8601DateTime, $maintainerId: ID, $module: String,
          $outcome: String, $limit: Int) {
      auditEvents(since: $since, until: $until, maintainerId: $maintainerId, module: $module,
                  outcome: $outcome, limit: $limit) {
        name module outcome occurredAt maintainerId login correlationId
      }
    }
  GQL

  # Postado como STRING JSON, não como Hash aninhado: um Hash vira
  # application/x-www-form-urlencoded, que só conhece string — `limit` (Int)
  # chegaria como "300" e o coercer estrito de graphql-ruby recusaria. JSON
  # de verdade é como um cliente GraphQL manda `variables` na prática (a
  # mesma forma que spec/requests/maintenance/graphql_spec.rb já prova que o
  # controller aceita).
  def audit_events!(headers: browser, **variables)
    post "/graphql", params: { query: QUERY, variables: variables.to_json }, headers: headers
    json.dig("data", "auditEvents")
  end

  def record!(name, outcome:, who: maintainer, module_name: "session", correlation_id: SecureRandom.uuid)
    MaintenanceAudit.record(name, outcome: outcome, module_name: module_name, maintainer_id: who.id,
                            credential: { "kind" => "session" }, correlation_id: correlation_id)
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!   # já grava maintenance.session.started
  end

  it "lists maintenance events newest first, resolving the login from the id" do
    record!("maintenance.session.failed", outcome: "rejected")

    events = audit_events!

    expect(events.first["name"]).to eq("maintenance.session.failed")
    expect(events.first["login"]).to eq(maintainer.email_address)
    expect(events.first["maintainerId"]).to eq(maintainer.id)
    expect(events.map { |e| e["occurredAt"] }).to eq(events.map { |e| e["occurredAt"] }.sort.reverse)

    # O evento em si continua sem e-mail: a Ruling R18 vale para o que é gravado.
    expect(PlatformEvent.where(name: "maintenance.session.failed").last.payload.to_json)
      .not_to include(maintainer.email_address)
  end

  it "keeps an attempt and its outcome together on one correlation id" do
    correlation_id = SecureRandom.uuid
    record!("maintenance.maintainer.invited", outcome: "attempted", module_name: "maintainer",
            correlation_id: correlation_id)
    record!("maintenance.maintainer.invited", outcome: "ok", module_name: "maintainer",
            correlation_id: correlation_id)

    events = audit_events!(module: "maintainer")

    expect(events.map { |e| e["outcome"] }).to contain_exactly("attempted", "ok")
    expect(events.map { |e| e["correlationId"] }.uniq).to eq([ correlation_id ])
  end

  it "filters by time, maintainer, module and outcome" do
    travel_to(3.days.ago) { record!("maintenance.session.ended", outcome: "ok") }
    record!("maintenance.session.failed", outcome: "rejected", who: other)
    record!("maintenance.maintainer.enrolled", outcome: "ok", module_name: "maintainer")

    recent = audit_events!(since: 1.day.ago.iso8601)
    expect(recent.map { |e| e["name"] }).not_to include("maintenance.session.ended")

    old_only = audit_events!(until: 2.days.ago.iso8601)
    expect(old_only.map { |e| e["name"] }).to eq([ "maintenance.session.ended" ])

    by_maintainer = audit_events!(maintainerId: other.id)
    expect(by_maintainer.map { |e| e["maintainerId"] }.uniq).to eq([ other.id ])
    expect(by_maintainer.first["login"]).to eq(other.email_address)

    by_module = audit_events!(module: "maintainer")
    expect(by_module.map { |e| e["module"] }.uniq).to eq([ "maintainer" ])

    rejected = audit_events!(outcome: "rejected")
    expect(rejected.map { |e| e["outcome"] }.uniq).to eq([ "rejected" ])
  end

  it "caps the limit instead of refusing it" do
    (Maintenance::AuditEventsQuery::LIMIT_MAX + 5).times { record!("maintenance.session.failed", outcome: "rejected") }

    events = audit_events!(limit: Maintenance::AuditEventsQuery::LIMIT_MAX + 100)

    expect(json["errors"]).to be_nil
    expect(events.size).to eq(Maintenance::AuditEventsQuery::LIMIT_MAX)
  end

  it "never shows platform events that are not maintenance events" do
    Platform.audit("operator.login", operator_id: SecureRandom.uuid)

    names = audit_events!(limit: Maintenance::AuditEventsQuery::LIMIT_MAX).map { |e| e["name"] }

    expect(names).to all(start_with("maintenance."))
  end

  # A recusa vem do analisador da Task 5: é o RED que aquela task fecha.
  it "refuses a service token, whatever its access level" do
    _record, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                                              city_slugs: [], expires_at: 10.days.from_now)

    # "Cookie" => "": o `before` já logou a sessão humana neste cliente de
    # teste; sem apagar o cookie aqui, a requisição carregaria os dois
    # (cookie + bearer) e cairia em "ambiguous_credentials" — outra recusa
    # real, mas não a do analisador que este exemplo prova.
    post "/graphql", params: { query: QUERY, variables: {} },
                     headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" }

    expect(json["errors"]).to be_present
    expect(json.dig("data", "auditEvents")).to be_nil
  end
end
