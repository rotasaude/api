# spec/requests/maintenance/city_analytics_spec.rb
require "rails_helper"

# Contratos §3 (F-14.9): analyticsIndicators lê o banco de PLATAFORMA sem abrir a
# cidade; analyticsStatus lê analytics_runs da cidade e é anulável — cidade
# inalcançável anula só ele, nunca `city`.
RSpec.describe "Maintenance city analytics", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "cy-an-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:monday) { (Time.zone.today - 14).beginning_of_week }

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  # Mesmo arranjo de login de spec/requests/maintenance/city_operations_spec.rb.
  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    expect(response).to have_http_status(:ok)
  end

  def gql!(query, **variables)
    post "/graphql", params: { query: query, variables: variables.to_json }, headers: browser
  end

  # Método, não constante: constante dentro de `describe` vaza para o escopo global.
  def indicators_query
    <<~GQL
      query($slug: String!, $from: ISO8601Date!, $to: ISO8601Date!) {
        city(slug: $slug) { slug analyticsIndicators(from: $from, to: $to) { weekStart indicator value suppressed } }
      }
    GQL
  end

  before do
    unless City.exists?(slug: TEST_CITY_A.slug)
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
    end
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!
  end

  it "analyticsIndicators: linhas da plataforma no intervalo, suprimido com value nulo, sem abrir a cidade" do
    CityAnalyticsIndicator.create!(city: city, week_start: monday, indicator: "triages_started", value: 40,
                                   suppressed: false, published_at: Time.current)
    CityAnalyticsIndicator.create!(city: city, week_start: monday, indicator: "no_show_pct", value: nil,
                                   suppressed: true, published_at: Time.current)
    CityAnalyticsIndicator.create!(city: city, week_start: monday - 70, indicator: "triages_started", value: 9,
                                   suppressed: false, published_at: Time.current)
    allow(Maintenance::CityReader).to receive(:call).and_call_original

    gql!(indicators_query, slug: city.slug, from: (monday - 7).iso8601, to: (monday + 6).iso8601)

    expect(json["errors"]).to be_nil
    expect(json.dig("data", "city", "analyticsIndicators")).to eq([
      { "weekStart" => monday.iso8601, "indicator" => "no_show_pct", "value" => nil, "suppressed" => true },
      { "weekStart" => monday.iso8601, "indicator" => "triages_started", "value" => 40.0, "suppressed" => false }
    ])
    expect(Maintenance::CityReader).not_to have_received(:call)
  end

  it "analyticsIndicators com from depois de to ou mais de 104 semanas: INVALID_RANGE" do
    gql!(indicators_query, slug: city.slug, from: monday.iso8601, to: (monday - 7).iso8601)
    expect(json["errors"].first.dig("extensions", "code")).to eq("INVALID_RANGE")

    gql!(indicators_query, slug: city.slug, from: (monday - 7 * 104).iso8601, to: monday.iso8601)
    expect(json["errors"].first.dig("extensions", "code")).to eq("INVALID_RANGE")
  end

  it "analyticsIndicators com exatamente 104 semanas: aceito" do
    CityAnalyticsIndicator.create!(city: city, week_start: monday - 7 * 103, indicator: "triages_started", value: 12,
                                   suppressed: false, published_at: Time.current)

    gql!(indicators_query, slug: city.slug, from: (monday - 7 * 103).iso8601, to: monday.iso8601)

    expect(json["errors"]).to be_nil
    expect(json.dig("data", "city", "analyticsIndicators")).to eq([
      { "weekStart" => (monday - 7 * 103).iso8601, "indicator" => "triages_started", "value" => 12.0, "suppressed" => false }
    ])
  end

  # Run.describe guarda classe + primeira linha: a linha DETAIL do PostgreSQL
  # traria o valor da linha que falhou (aqui, um CPF de mentira).
  it "analyticsStatus de um run failed: lastError só com a primeira linha, sem DETAIL nem CPF, e stale" do
    message = "ERROR:  duplicate key value violates unique constraint \"index_citizens_on_cpf\"\n" \
              "DETAIL:  Key (cpf)=(123.456.789-09) already exists."
    allow(Analytics::Consolidate).to receive(:call).and_raise(ActiveRecord::RecordNotUnique, message)
    expect(scheduled_run!.status).to eq("failed")

    gql!('query($slug: String!) { city(slug: $slug) { analyticsStatus { lastRunStatus lastError stale } } }',
         slug: city.slug)

    expect(json["errors"]).to be_nil
    expect(json.dig("data", "city", "analyticsStatus")).to eq(
      "lastRunStatus" => "failed", "stale" => true,
      "lastError" => "ActiveRecord::RecordNotUnique: ERROR:  duplicate key value violates unique constraint " \
                     "\"index_citizens_on_cpf\""
    )
  end

  it "analyticsStatus: estado do pipeline lido de analytics_runs da cidade" do
    run = consolidated_run!(finished_at: 2.hours.ago)

    gql!('query($slug: String!) { city(slug: $slug) { analyticsStatus { lastRunStatus lastSucceededAt lastPublishedAt lastError stale } } }',
         slug: city.slug)

    expect(json["errors"]).to be_nil
    status = json.dig("data", "city", "analyticsStatus")
    expect(status).to include("lastRunStatus" => "succeeded", "lastError" => nil, "stale" => false)
    expect(Time.iso8601(status["lastSucceededAt"])).to be_within(1.second).of(run.finished_at)
    expect(Time.iso8601(status["lastPublishedAt"])).to be_within(1.second).of(run.published_at)
  end

  it "cidade inalcançável: analyticsStatus nulo com erro de campo, e o resto de `city` responde" do
    allow(Maintenance::CityReader).to receive(:call).and_raise(Maintenance::CityReader::Unreachable, "PG::ConnectionBad: x")

    gql!('query($slug: String!) { city(slug: $slug) { slug analyticsStatus { stale } } }', slug: city.slug)

    expect(json.dig("data", "city", "slug")).to eq(city.slug)
    expect(json.dig("data", "city", "analyticsStatus")).to be_nil
    expect(json["errors"].first.dig("extensions", "code")).to eq("CITY_UNREACHABLE")
  end
end
