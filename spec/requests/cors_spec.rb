require "rails_helper"

# Plano 6: a lista estática ALLOWED_ORIGINS não enumera N cidades. A origem é
# aceita quando o host dela resolve uma cidade servível do catálogo, ou é um
# host reservado da plataforma (admin/auth/api/www).
RSpec.describe "CORS", type: :request do
  def cors_header_for(origin)
    get "/session", headers: { "Origin" => origin, "Host" => "#{TEST_CITY_A.slug}.rotasaude.app" }
    response.headers["Access-Control-Allow-Origin"]
  end

  before { CityCatalog.reset_cache! }

  it "allows the origin of a city in the catalog" do
    expect(cors_header_for("http://#{TEST_CITY_A.slug}.localhost:5175")).to eq("http://#{TEST_CITY_A.slug}.localhost:5175")
  end

  it "allows the platform console origin" do
    expect(cors_header_for("http://admin.localhost:5174")).to eq("http://admin.localhost:5174")
  end

  it "refuses a host that is not a city" do
    expect(cors_header_for("http://naoexiste.localhost:5175")).to be_nil
  end

  it "refuses a malformed origin" do
    expect(cors_header_for("not a url")).to be_nil
  end
end
