# spec/requests/maintenance/bnafar_status_spec.rb
require "rails_helper"

# Módulo 27b, Q9 e Q17: o maintenance troca o ambiente do envio à BNAFAR só
# fora de produção (setBnafarEnvironment, sem TOTP, como setCityPecOrigin) e lê
# a situação (cityBnafarStatus). A importação do saldo não está aqui (Q11).
RSpec.describe "Maintenance: ambiente e situação do envio à BNAFAR", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "bnafar-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:set_env) do
    "mutation($citySlug: String!, $environment: String!, $code: String) { setBnafarEnvironment(citySlug: $citySlug, " \
      "environment: $environment, code: $code) { ok errors { path message } } }"
  end

  def with_fresh_totp
    @totp_clock = (@totp_clock || Time.current) + 31.seconds
    travel_to(@totp_clock) { yield(ROTP::TOTP.new(maintainer.otp_secret).now) }
  end
  let(:status_query) do
    "query($citySlug: String!) { cityBnafarStatus(citySlug: $citySlug) { environment environmentEditable enabledDomains " \
      "alert { late lost rejected lastFinishedOn } startedOn } }"
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query, **variables) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)

  before do
    unless City.exists?(slug: TEST_CITY_A.slug)
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active", database_url: TEST_CITY_A.database_url,
                   encryption_key: TEST_CITY_A.encryption_key, schema_version: CitySchema.expected_version.to_s)
    end
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    BnafarSetting.ensure_defaults!
    BnafarSetting.where(id: 1).update_all(environment: "production", updated_by_maintainer_id: nil)
    travel_to(1.minute.ago) do
      post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
      post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
                                 headers: browser
    end
  end
  after { CityCatalog.reset_cache! }

  it "setBnafarEnvironment(homologation) em test passa e audita só o environment" do
    gql!(set_env, citySlug: city.slug, environment: "homologation")

    expect(json.dig("data", "setBnafarEnvironment")).to eq("ok" => true, "errors" => [])
    setting = BnafarSetting.current
    expect(setting.environment).to eq("homologation")
    expect(setting.updated_by_maintainer_id).to eq(maintainer.id)
    events = PlatformEvent.where(name: "maintenance.bnafar.environment_changed")
    expect(events.map { |e| e.payload["outcome"] }).to contain_exactly("attempted", "ok")
    expect(events.map(&:payload)).to all(include("environment" => "homologation", "module" => "bnafar"))
    expect(events.flat_map { |e| e.payload.keys }.uniq - %w[outcome module maintainer_id credential correlation_id city_slug environment ip request_id]).to be_empty

  end

  it "staging → production sem code (ou com código errado) → erro de step-up e nada gravado" do
    BnafarSetting.where(id: 1).update_all(environment: "homologation")

    gql!(set_env, citySlug: city.slug, environment: "production")
    expect(json.dig("data", "setBnafarEnvironment", "errors", 0)).to include("path" => "code", "message" => "código inválido")
    gql!(set_env, citySlug: city.slug, environment: "production", code: "000000")
    expect(json.dig("data", "setBnafarEnvironment", "ok")).to be(false)
    expect(BnafarSetting.current.environment).to eq("homologation")
    expect(PlatformEvent.where(name: "maintenance.bnafar.environment_changed").map { |e| e.payload["outcome"] }.uniq).to contain_exactly("attempted", "rejected")
  end

  it "→ production com code válido → ok, e o código não é auditado" do
    BnafarSetting.where(id: 1).update_all(environment: "homologation")
    code = nil
    with_fresh_totp { |c| code = c; gql!(set_env, citySlug: city.slug, environment: "production", code: c) }

    expect(json.dig("data", "setBnafarEnvironment")).to eq("ok" => true, "errors" => [])
    expect(BnafarSetting.current).to have_attributes(environment: "production", updated_by_maintainer_id: maintainer.id)
    expect(PlatformEvent.where(name: "maintenance.bnafar.environment_changed").map { |e| e.payload.to_s }.join).not_to include(code)
  end

  it "ambiente fora do catálogo → erro no campo environment, sem auditoria nem gravação" do
    gql!(set_env, citySlug: city.slug, environment: "sandbox ' OR 1=1")

    expect(json.dig("data", "setBnafarEnvironment", "ok")).to be(false)
    expect(json.dig("data", "setBnafarEnvironment", "errors", 0, "path")).to eq("environment")
    expect(BnafarSetting.current.environment).to eq("production")
    expect(PlatformEvent.where(name: "maintenance.bnafar.environment_changed")).to be_empty
    expect(PlatformEvent.all.map { |e| e.payload.to_s }.join).not_to include("OR 1=1")
  end

  it "com Rails.env production (stub) → environment_not_allowed e nada gravado" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    gql!(set_env, citySlug: city.slug, environment: "homologation")

    expect(json.dig("data", "setBnafarEnvironment")).to include("ok" => false)
    expect(json.dig("data", "setBnafarEnvironment", "errors", 0)).to include("path" => "environment", "message" => "environment_not_allowed")
    expect(BnafarSetting.current.environment).to eq("production")
    expect(PlatformEvent.where(name: "maintenance.bnafar.environment_changed").map { |e| e.payload["outcome"] })
      .to contain_exactly("attempted", "rejected")
  end

  it "cityBnafarStatus mostra ambiente, editável, domínios, alerta e started_on" do
    pharmacy_city!
    BnafarSetting.where(id: 1).update_all(environment: "homologation", started_on: Date.new(2026, 11, 20))
    bnafar_on!(city, domains: %w[bnafar_medications])
    bnafar_credential!(environment: "homologation") # o ambiente em uso é o de homologação
    lost = bnafar_submission!(reference_on: Time.zone.today - 5, status: "lost", environment: "homologation")
    bnafar_record!(lost, status: "rejected", error_codes: [ "MSG12" ])
    bnafar_submission!(reference_on: Time.zone.today - 3, status: "finished", environment: "homologation")

    gql!(status_query, citySlug: city.slug)

    status = json.dig("data", "cityBnafarStatus")
    expect(status).to include("environment" => "homologation", "environmentEditable" => true, "startedOn" => "2026-11-20")
    expect(status["enabledDomains"]).to eq(Bnafar::Gate.domains(city))
    expect(status["enabledDomains"]).to eq([ "medication" ])
    expect(status["alert"]).to include("lost" => 1, "rejected" => 0, "lastFinishedOn" => (Time.zone.today - 3).iso8601)
    expect(json["errors"]).to be_nil
  end

  it "cityBnafarStatus com Rails.env production: ambiente production e não editável" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    gql!(status_query, citySlug: city.slug)

    expect(json.dig("data", "cityBnafarStatus")).to include("environment" => "production", "environmentEditable" => false,
                                                            "enabledDomains" => [], "startedOn" => nil)
  end

  it "token: a leitura fora do escopo da cidade → CITY_OUT_OF_SCOPE; a escrita é só de sessão humana, nada gravado" do
    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                                             city_slugs: [ city.slug ], expires_at: 5.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
    other = TEST_CITY_B.slug

    post "/graphql", params: { query: set_env, variables: { citySlug: city.slug, environment: "homologation" }.to_json }, headers: bearer
    expect(json["errors"].first["message"]).to include("setBnafarEnvironment")
    post "/graphql", params: { query: status_query, variables: { citySlug: city.slug }.to_json }, headers: bearer
    expect(json["errors"]).to be_nil
    post "/graphql", params: { query: status_query, variables: { citySlug: other }.to_json }, headers: bearer
    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_OUT_OF_SCOPE")
    expect(json.dig("data", "cityBnafarStatus")).to be_nil
    expect(BnafarSetting.current.environment).to eq("production")
  end

  it "o SDL do ambiente e da situação é o combinado com o maintenance" do
    sdl = Maintenance::Schema.to_definition
    # Só as linhas de campo (`  nome: Tipo`): as descrições (aspas triplas) ficam de fora.
    fields = ->(type) { sdl[/^type #{type} \{\n.*?^\}/m].scan(/^  (\w+: .+)$/).flatten }

    expect(sdl).to match(/setBnafarEnvironment\([^)]*\benvironment: String![^)]*\): SetBnafarEnvironmentPayload/m)
    expect(sdl).to match(/setBnafarEnvironment\([^)]*\bcode: String(?![!\w])[^)]*\): SetBnafarEnvironmentPayload/m)
    expect(sdl).to match(/cityBnafarStatus\(citySlug: String!\): CityBnafarStatus/)
    expect(fields.call("SetBnafarEnvironmentPayload")).to eq([ "errors: [UserError!]!", "ok: Boolean!" ])
    expect(fields.call("CityBnafarStatus")).to eq(
      [ "alert: BnafarAlert!", "enabledDomains: [String!]!", "environment: String!", "environmentEditable: Boolean!", "startedOn: ISO8601Date" ]
    )
    expect(fields.call("BnafarAlert")).to eq([ "lastFinishedOn: ISO8601Date", "late: Int!", "lost: Int!", "rejected: Int!" ])
  end
end
