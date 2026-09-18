require "rails_helper"

# Spec §8: `city(slug:)` é o ÚNICO caminho para dentro do banco de uma cidade, e
# é onde o escopo do token é aplicado. Teto de 5 cidades por operação.
RSpec.describe "Maintenance city", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "cy-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
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

  def gql!(query, headers: browser, **variables)
    post "/graphql", params: { query: query, variables: variables.to_json }, headers: headers
  end

  # P1: a query mora num método, não numa constante de topo — uma constante
  # aqui viveria em Object e colidiria com a CITY/QUERY de outros specs.
  def city_query
    <<~GQL
      query($slug: String!) {
        city(slug: $slug) {
          slug name uf status schemaVersion schemaBehind
          channel { phoneNumberId wabaId displayPhoneNumber active }
        }
      }
    GQL
  end

  # Mesmo padrão de cities_spec.rb: cidade de harness registrada direto no
  # catálogo de plataforma.
  def register_city!(test_city)
    return if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let!(:archived_city) do
    City.create!(slug: "arquivada-#{SecureRandom.hex(3)}", name: "Cidade Arquivada", uf: "sp",
                status: "archived", schema_version: "0",
                # Arquivada não abre conexão — a URL nunca é discada, e é de
                # propósito claramente não roteável.
                database_url: "postgres://unreachable.invalid/none",
                encryption_key: SecureRandom.hex(32))
  end

  # P2: linhas extras só-de-plataforma para o exemplo de 6 cidades. O
  # analisador de teto recusa na ANÁLISE, antes de qualquer resolver abrir
  # conexão (city_budget_spec cobre isso com `expect(CityConnection).not_to
  # receive(:with)`), então uma URL que nunca é discada serve.
  let!(:extra_cities) do
    Array.new(3) do |i|
      City.create!(slug: "extra-#{i}-#{SecureRandom.hex(3)}", name: "Extra #{i}", status: "provisioning",
                  schema_version: "0", database_url: "postgres://unreachable.invalid/extra-#{i}",
                  encryption_key: SecureRandom.hex(32))
    end
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

  it "answers the platform side of a city, never the channel token" do
    gql!(city_query, slug: city.slug)

    answered = json.dig("data", "city")
    expect(answered).to include("slug" => city.slug, "status" => city.status)
    expect(answered["channel"]&.keys).to satisfy { |keys| keys.nil? || keys.exclude?("accessToken") }
    expect(response.body).not_to include("access_token")
  end

  it "answers nil for a slug that does not exist" do
    gql!(city_query, slug: "cidade-que-nao-existe")

    expect(json.dig("data", "city")).to be_nil
    expect(json["errors"]).to be_nil
  end

  it "refuses a city outside a token's scope, and answers the one inside it" do
    other = City.find_by!(slug: TEST_CITY_B.slug)

    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [ city.slug ], expires_at: 5.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}", "Cookie" => "" }

    gql!(city_query, slug: other.slug, headers: bearer)
    expect(json.dig("data", "city")).to be_nil
    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_OUT_OF_SCOPE")

    gql!(city_query, slug: city.slug, headers: bearer)
    expect(json.dig("data", "city", "slug")).to eq(city.slug)
  end

  it "refuses an operation that touches more than five cities, before executing it" do
    slugs = City.order(:slug).limit(6).pluck(:slug)
    expect(slugs.size).to eq(6)

    query = "{ " + slugs.each_with_index.map { |s, i| "c#{i}: city(slug: \"#{s}\") { slug }" }.join(" ") + " }"
    expect(CityConnection).not_to receive(:with)

    gql!(query)

    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_BUDGET_EXCEEDED")
    expect(json["data"]).to be_nil
  end

  it "counts aliases and fragments toward the same budget" do
    slug = city.slug
    query = <<~GQL
      { a: city(slug: "#{slug}") { ...s } b: city(slug: "#{slug}") { ...s } c: city(slug: "#{slug}") { ...s }
        d: city(slug: "#{slug}") { ...s } e: city(slug: "#{slug}") { ...s } f: city(slug: "#{slug}") { ...s } }
      fragment s on City { slug }
    GQL

    gql!(query)

    expect(json["errors"].first["extensions"]["code"]).to eq("CITY_BUDGET_EXCEEDED")
  end
end
