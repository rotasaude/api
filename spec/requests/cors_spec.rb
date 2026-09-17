require "rails_helper"

# Plano 6: CORS valida que a Origin é IDÊNTICA ao host que publicamos para cada
# slug (CityPublicUrl.base_for_slug), e ANTES de consultar o catálogo. Assim um
# atacante não consegue usar slug.attacker.example ou admin.attacker.example.
RSpec.describe "CORS", type: :request do
  MAINTENANCE_API_HOST = "maintenance-api.rotasaude.app".freeze
  MAINTENANCE_ORIGIN = "https://maintenance.rotasaude.app".freeze

  def cors_header_for(origin, host: "#{TEST_CITY_A.slug}.rotasaude.app")
    get "/session", headers: { "Origin" => origin, "Host" => host }
    response.headers["Access-Control-Allow-Origin"]
  end

  def with_maintenance_origin
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("MAINTENANCE_FRONTEND_ORIGIN", "").and_return(MAINTENANCE_ORIGIN)
  end

  before { CityCatalog.reset_cache! }

  it "allows the origin of a city in the catalog" do
    expect(cors_header_for("http://#{TEST_CITY_A.slug}.localhost:5175")).to eq("http://#{TEST_CITY_A.slug}.localhost:5175")
  end

  it "allows the platform console origin through ALLOWED_ORIGINS" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("ALLOWED_ORIGINS", "").and_return("http://admin.localhost:5174")
    expect(cors_header_for("http://admin.localhost:5174")).to eq("http://admin.localhost:5174")
  end

  it "refuses a fake parent domain" do
    expect(cors_header_for("http://#{TEST_CITY_A.slug}.attacker.example")).to be_nil
  end

  it "refuses a reserved label on a foreign domain" do
    expect(cors_header_for("http://admin.attacker.example")).to be_nil
  end

  it "refuses a host that is not a city" do
    expect(cors_header_for("http://naoexiste.localhost:5175")).to be_nil
  end

  it "refuses a malformed origin" do
    expect(cors_header_for("not a url")).to be_nil
  end

  it "refuses a city that is not active" do
    City.find_by!(slug: TEST_CITY_A.slug).update!(status: "suspended")
    CityCatalog.reset_cache!
    expect(cors_header_for("http://#{TEST_CITY_A.slug}.localhost:5175")).to be_nil
  end

  # I6 (fix round 2): o casamento de resource do rack-cors é por CAMINHO, e
  # /session existe nos dois blocos. Sem separar por HOST, uma origem de cidade
  # ganhava preflight credenciado no host da API de manutenção e vice-versa — e
  # como todos os hosts são do mesmo site, SameSite=Strict não segura o cookie.
  it "allows the maintenance frontend only on the maintenance API host" do
    with_maintenance_origin

    expect(cors_header_for(MAINTENANCE_ORIGIN, host: MAINTENANCE_API_HOST)).to eq(MAINTENANCE_ORIGIN)
    expect(cors_header_for(MAINTENANCE_ORIGIN)).to be_nil
  end

  it "refuses a city origin, and the console origin, on the maintenance API host" do
    with_maintenance_origin
    allow(ENV).to receive(:fetch).with("ALLOWED_ORIGINS", "").and_return("http://admin.localhost:5174")

    expect(cors_header_for("http://#{TEST_CITY_A.slug}.localhost:5175", host: MAINTENANCE_API_HOST)).to be_nil
    expect(cors_header_for("http://admin.localhost:5174", host: MAINTENANCE_API_HOST)).to be_nil
  end

  it "refuses every origin on the maintenance API host when no origin is configured" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("MAINTENANCE_FRONTEND_ORIGIN", "").and_return("")

    expect(cors_header_for(MAINTENANCE_ORIGIN, host: MAINTENANCE_API_HOST)).to be_nil
  end

  it "is scheme- and port-exact against the production shape of CITY_PUBLIC_BASE_TEMPLATE" do
    # A suíte só exercitava a forma de dev (http, porta 5175). A regra é
    # exata em scheme e porta — este exemplo cobre a forma de produção (https,
    # sem porta), pra um https ↔ http trocado não passar batido.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything)
      .and_return("https://%{slug}.rota-saude.example")

    expect(cors_header_for("https://#{TEST_CITY_A.slug}.rota-saude.example"))
      .to eq("https://#{TEST_CITY_A.slug}.rota-saude.example")
    expect(cors_header_for("http://#{TEST_CITY_A.slug}.rota-saude.example")).to be_nil
  end
end
