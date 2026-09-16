require "rails_helper"

# Plano 6: CORS valida que a Origin é IDÊNTICA ao host que publicamos para cada
# slug (CityPublicUrl.base_for_slug), e ANTES de consultar o catálogo. Assim um
# atacante não consegue usar slug.attacker.example ou admin.attacker.example.
RSpec.describe "CORS", type: :request do
  def cors_header_for(origin)
    get "/session", headers: { "Origin" => origin, "Host" => "#{TEST_CITY_A.slug}.rotasaude.app" }
    response.headers["Access-Control-Allow-Origin"]
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
end
