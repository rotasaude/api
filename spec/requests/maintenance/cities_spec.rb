require "rails_helper"

# Spec §8: `cities` lê SÓ o banco de plataforma — nenhuma conexão de cidade é
# aberta — e um token só enxerga as cidades do seu escopo.
RSpec.describe "Maintenance cities", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "ct-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
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

  # P1: a query mora num método, não numa constante de topo — uma constante
  # aqui viveria em Object e sobrescreveria a QUERY de audit_events_spec.rb.
  def cities_query
    <<~GQL
      query($status: CityStatus) {
        cities(status: $status) { slug name uf status schemaVersion schemaBehind createdAt }
      }
    GQL
  end

  def cities!(headers: browser, **variables)
    post "/graphql", params: { query: cities_query, variables: variables.to_json }, headers: headers
    json.dig("data", "cities")
  end

  # P2: `cities` nunca abre conexão de cidade, então as cidades do exemplo são
  # registradas direto no catálogo de plataforma — como `use_test_city_host!`
  # já faz para TEST_CITY_A (a única que o `before(type: :request)` global
  # registra). `uf` fica de fora de propósito: nem TEST_CITY_A nem TEST_CITY_B
  # setam (CityTestDatabases.city não seta), e é exatamente esse o caso que
  # prova P6 — `uf` é `null: true` porque a coluna é opcional no catálogo de
  # verdade, e uma cidade sem valor não pode derrubar a lista inteira.
  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let!(:archived_city) do
    City.create!(slug: "arquivada-#{SecureRandom.hex(3)}", name: "Cidade Arquivada", uf: "sp",
                status: "archived", schema_version: "0",
                # Arquivada não abre conexão (Ruling 5): a URL nunca é discada, e
                # é de propósito claramente não roteável — nunca uma URL real.
                database_url: "postgres://unreachable.invalid/none",
                encryption_key: SecureRandom.hex(32))
  end

  before do
    register_city!(TEST_CITY_A)
    register_city!(TEST_CITY_B)
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    login!
  end

  it "lists every registered city, ordered by slug, without opening a city connection" do
    expect(CityConnection).not_to receive(:with)

    listed = cities!

    expect(listed.map { |c| c["slug"] }).to eq(City.order(:slug).pluck(:slug))
    expect(listed.first.keys)
      .to contain_exactly(*%w[slug name uf status schemaVersion schemaBehind createdAt])
  end

  # P6 (fix round 1): a coluna é opcional — uma cidade sem `uf` não pode
  # nulificar `[CitySummary!]!` inteiro. TEST_CITY_A prova o `nil` (nenhum
  # registro do harness seta `uf`); archived_city, ao lado dela na mesma
  # resposta, prova que uma cidade COM valor continua saindo normalmente.
  it "lists a city without a uf alongside the rest, instead of nulling the whole response" do
    expect(City.find_by!(slug: TEST_CITY_A.slug).uf).to be_nil

    listed = cities!

    without_uf = listed.find { |c| c["slug"] == TEST_CITY_A.slug }
    expect(without_uf).to include("uf" => nil)

    with_uf = listed.find { |c| c["slug"] == archived_city.slug }
    expect(with_uf).to include("uf" => "sp")
  end

  it "filters by status" do
    archived = City.where(status: "archived").pluck(:slug)

    listed = cities!(status: "ARCHIVED")

    expect(listed.map { |c| c["slug"] }).to match_array(archived)
  end

  it "never exposes a secret of the catalog" do
    cities!

    expect(response.body).not_to include("database_url")
    expect(response.body).not_to include("encryption_key")
    City.find_each { |city| expect(response.body).not_to include(city.database_url) }
  end

  it "shows a token only the cities of its scope" do
    scoped_slug = City.order(:slug).first.slug
    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [ scoped_slug ], expires_at: 5.days.from_now)

    listed = cities!(headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" })

    expect(listed.map { |c| c["slug"] }).to eq([ scoped_slug ])
  end

  it "shows a token with an empty scope every city" do
    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [], expires_at: 5.days.from_now)

    listed = cities!(headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" })

    expect(listed.map { |c| c["slug"] }).to eq(City.order(:slug).pluck(:slug))
  end
end
