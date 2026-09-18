require "rails_helper"

# Spec §8: dados operacionais entram como metadado e contagem. O payload de um
# evento de domínio, o conteúdo/assinatura de um relatório e a mensagem de uma
# exceção são dado de cidadão (ou podem carregá-lo) — nenhum deles sai daqui
# (P10: só a CLASSE da exceção, nunca a mensagem).
RSpec.describe "Maintenance city operations", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "cy-op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  # Mesmo arranjo de login de spec/requests/maintenance/city_spec.rb. Não
  # extraído para spec/support: o próprio harness (city_request_auth.rb) traz
  # a lição de um `before(type: :request)` global vazado por um helper
  # compartilhado (ver comentário no topo daquele arquivo) — e as outras 8
  # specs de manutenção já repetem este mesmo bloco, sem exceção.
  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    expect(response).to have_http_status(:ok)
  end

  def gql!(query, headers: browser, **variables)
    post "/graphql", params: { query: query, variables: variables.to_json }, headers: headers
  end

  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  before do
    register_city!(TEST_CITY_A)
    register_city!(TEST_CITY_B)
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!
  end

  # Uma linha de cada tabela que `counts`/`operations` toca, dentro da MESMA
  # sessão de TEST_CITY_A que o harness já abriu (P1/P2: nunca contagem vazia
  # provando nada). `marker` é uma string reconhecível plantada em payload,
  # assinatura/conteúdo do relatório e mensagem da exceção — cada exemplo
  # confirma que ELA, especificamente, nunca aparece no corpo da resposta.
  def seed_operational_data!(marker:)
    pd = ProtocolDefinition.create!(name: "resp", version: 3, status: "active",
                                    definition: { "name" => "resp", "version" => 3, "start_step_id" => "s1",
                                                  "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean" } ] })
    convo = Conversation.create!(phone: "+5541999#{rand(100_000..999_999)}", state: "completed")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "resp",
                            status: "completed", tier: "alta", answers: {})
    ReportSnapshot.create!(triage: triage, protocol_definition: pd, token: "tok-#{SecureRandom.hex(4)}",
                           signature: "sig-#{marker}", payload: { "clinical_note" => marker },
                           outcome: { "tier" => "alta" }, expires_at: 10.days.from_now)
    Consent.create!(conversation: convo, version: 9, policy_text_sha: "sha", channel: "whatsapp", given_at: 2.days.ago)
    InboundMessage.create!(message_id: "wamid-#{SecureRandom.hex(4)}", from: "+5541999990000", kind: "text",
                           raw: { "type" => "text", "text" => { "body" => marker } }.to_json)
    User.create!(email_address: "staff-#{SecureRandom.hex(3)}@cidade.gov.br", password: "s3nha-staff-1",
                otp_secret: ROTP::Base32.random, otp_enabled: true)
    DomainEvent.create!(name: "triage.completed", occurred_at: Time.current, published_at: Time.current,
                        payload: { "clinical_note" => marker })

    job = SolidQueue::Job.create!(queue_name: "default", class_name: "NotifyCitizenJob",
                                  active_job_id: SecureRandom.uuid, arguments: "[]", scheduled_at: Time.current)
    SolidQueue::FailedExecution.create!(job: job,
      error: { exception_class: "ArgumentError", message: "invalid phone #{marker}", backtrace: [] })
  end

  it "counts citizen data instead of showing it" do
    seed_operational_data!(marker: "+5541900000000")

    gql!('query($slug: String!) { city(slug: $slug) { counts { users conversations triages inboundMessages reportSnapshots consents } } }',
         slug: city.slug)

    expect(json["errors"]).to be_nil
    counts = json.dig("data", "city", "counts")
    expect(counts.values).to all(be_a(Integer))
    expect(counts).to eq("users" => 1, "conversations" => 1, "triages" => 1, "inboundMessages" => 1,
                         "reportSnapshots" => 1, "consents" => 1)
  end

  it "lists domain events as metadata, never their payload" do
    marker = "clinical-marker-#{SecureRandom.hex(4)}"
    seed_operational_data!(marker: marker)

    gql!('query($slug: String!) { city(slug: $slug) { operations { domainEvents { name occurredAt publishedAt } } } }',
         slug: city.slug)

    expect(json["errors"]).to be_nil
    events = json.dig("data", "city", "operations", "domainEvents")
    expect(events).to include(include("name" => "triage.completed", "publishedAt" => be_present))
    expect(response.body).not_to include("payload")
    expect(response.body).not_to include(marker)
  end

  it "lists report snapshots and dashboard metrics without their content" do
    marker = "clinical-marker-#{SecureRandom.hex(4)}"
    seed_operational_data!(marker: marker)
    DashboardMetric.bump!(dimension: "triages_by_tier", period: Date.current.iso8601, key: "alta")

    gql!('query($slug: String!) { city(slug: $slug) { operations {
            reportSnapshots { id createdAt expiresAt }
            dashboardMetrics { dimension period label value computedAt }
          } } }', slug: city.slug)

    expect(json["errors"]).to be_nil
    snapshots = json.dig("data", "city", "operations", "reportSnapshots")
    expect(snapshots.size).to eq(1)
    expect(snapshots.first.keys).to match_array(%w[id createdAt expiresAt])
    expect(snapshots.first["createdAt"]).to be_present

    metrics = json.dig("data", "city", "operations", "dashboardMetrics")
    expect(metrics).to include("dimension" => "triages_by_tier", "period" => Date.current.iso8601,
                               "label" => "alta", "value" => 1, "computedAt" => be_present)

    %w[payload signature outcome token].each { |forbidden| expect(response.body).not_to include(forbidden) }
    expect(response.body).not_to include(marker)
  end

  it "lists failed jobs with a redacted error" do
    marker = "+5541988887777"
    seed_operational_data!(marker: marker)

    gql!('query($slug: String!) { city(slug: $slug) { operations { failedJobs { className failedAt errorClass } } } }',
         slug: city.slug)

    expect(json["errors"]).to be_nil
    jobs = json.dig("data", "city", "operations", "failedJobs")
    expect(jobs).to include("className" => "NotifyCitizenJob", "errorClass" => "ArgumentError", "failedAt" => be_present)
    jobs.each { |job| expect(job["errorClass"].to_s).not_to match(%r{://[^/\s@]+:[^/\s@]+@}) }
    expect(response.body).not_to include(marker)
    expect(response.body).not_to include("invalid phone")
  end

  # P4: exemplo real de cidade inalcançável na subárvore de operações — stub de
  # CityReader levantando Unreachable, e o erro sai com CITY_UNREACHABLE em
  # cada campo (counts e operations abrem conexão cada um o seu), enquanto a
  # outra cidade responde normalmente.
  it "reports an unreachable city on the operations subtree too" do
    other = City.find_by!(slug: TEST_CITY_B.slug)
    seed_operational_data!(marker: "n/a")

    allow(Maintenance::CityReader).to receive(:call).and_call_original
    allow(Maintenance::CityReader).to receive(:call).with(having_attributes(slug: other.slug))
      .and_raise(Maintenance::CityReader::Unreachable, "PG::ConnectionBad: connection to ://***@db failed")

    query = <<~GQL
      { ok: city(slug: "#{city.slug}") { counts { users } }
        bad: city(slug: "#{other.slug}") { counts { users } operations { domainEvents { name } } } }
    GQL
    gql!(query)

    expect(json.dig("data", "ok", "counts", "users")).to eq(1)
    expect(json.dig("data", "bad", "counts")).to be_nil
    expect(json.dig("data", "bad", "operations")).to be_nil

    bad_errors = json["errors"].select { |e| e["path"]&.first == "bad" }
    expect(bad_errors.size).to eq(2)
    expect(bad_errors.map { |e| e["extensions"]["code"] }.uniq).to eq([ "CITY_UNREACHABLE" ])
    expect(bad_errors.map { |e| e["message"] }).to all(include("://***@"))
  end
end
