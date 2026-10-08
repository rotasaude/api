require "rails_helper"

# ADR 0028 (contratos §3): só o mantenedor liga e desliga, auditado; o
# liga/desliga funciona com a cidade fora do ar; usable/missing degradam.
RSpec.describe "Interruptores na API de manutenção", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "cf-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query, **variables) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
                               headers: browser
    expect(response).to have_http_status(:ok)
  end

  def set_feature(slug, key, enabled)
    gql!(<<~GQL, citySlug: slug, key: key, enabled: enabled)
      mutation($citySlug: String!, $key: String!, $enabled: Boolean!) {
        setCityFeature(citySlug: $citySlug, key: $key, enabled: $enabled) {
          ok errors { path message } feature { key enabled usable missing changedAt changedBy }
        }
      }
    GQL
    json.dig("data", "setCityFeature")
  end

  # Mesmo arranjo de spec/requests/maintenance/city_spec.rb.
  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                 database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                 schema_version: CitySchema.expected_version.to_s)
  end

  # O catálogo em memória guardaria a cidade inalcançável do exemplo seguinte.
  after { CityCatalog.reset_cache! }

  before do
    register_city!(TEST_CITY_A)
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!
  end

  it "liga, devolve o interruptor e audita o par e o fato" do
    payload = set_feature(city.slug, "cadsus_lookup", true)

    expect(payload["ok"]).to be(true)
    expect(payload["feature"]).to include("key" => "cadsus_lookup", "enabled" => true, "usable" => false,
                                          "missing" => [ "credential_missing:cadsus" ],
                                          "changedBy" => maintainer.email_address)
    expect(CityFeature.find_by!(city: city, key: "cadsus_lookup").enabled).to be(true)
    expect(PlatformEvent.where(name: "maintenance.city.feature_changed").order(:created_at).pluck(Arel.sql("payload->>'outcome'")))
      .to eq(%w[attempted ok])
    expect(PlatformEvent.find_by!(name: "city.feature_changed").payload)
      .to include("city_id" => city.id, "key" => "cadsus_lookup", "enabled" => true, "maintainer_id" => maintainer.id)
  end

  it "chave fora do catálogo: erro em key, nada gravado nem auditado" do
    payload = set_feature(city.slug, "rnds", true)
    expect(payload).to include("ok" => false, "errors" => [ { "path" => "key", "message" => "unknown_feature" } ])
    expect(CityFeature.count).to eq(0)
    expect(PlatformEvent.where("name LIKE ?", "%feature_changed")).to be_empty
  end

  it "cidade inexistente: erro em citySlug" do
    payload = set_feature("nao-existe", "cadsus_lookup", true)
    expect(payload["ok"]).to be(false)
    expect(payload["errors"].first["path"]).to eq("citySlug")
  end

  it "cidade ativa mas inalcançável: liga mesmo assim e degrada" do
    down = create(:city)
    # Sem discar de verdade: o harness de fixtures transacionais não aguenta um
    # pool de cidade que nunca conectou (mesmo arranjo de city_spec.rb).
    allow(CityConnection).to receive(:with).and_call_original
    allow(CityConnection).to receive(:with).with(having_attributes(slug: down.slug))
      .and_raise(ActiveRecord::ConnectionNotEstablished, "PG::ConnectionBad: down")

    payload = set_feature(down.slug, "ledi_export", true)
    expect(payload["ok"]).to be(true)
    expect(payload["feature"]).to include("enabled" => true, "usable" => false, "missing" => [ "city_unreachable" ])
  end

  it "city { features recordMode } lê plataforma e cidade" do
    city.update!(record_mode: "integrated")
    gql!(<<~GQL, slug: city.slug)
      query($slug: String!) { city(slug: $slug) { recordMode features { key description enabled usable missing } } }
    GQL
    data = json.dig("data", "city")
    expect(data["recordMode"]).to eq("integrated")
    expect(data["features"].map { |f| f["key"] }).to eq(%w[ledi_export cadsus_lookup clinical_record])
    expect(data["features"].first["missing"]).to eq(%w[pec_url_missing ibge_code_missing credential_missing:ledi])
  end
end
