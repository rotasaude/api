require "rails_helper"

# Spec da API de manutenção §3: o host maintenance-api.* é da PLATAFORMA, e
# maintenance.* é do frontend. Nenhum dos dois pode resolver cidade — senão um
# slug cadastrado roubaria o host da ferramenta que dá acesso a todas as cidades.
RSpec.describe "Maintenance API host" do
  it "reserves both maintenance labels, so no city can take them" do
    expect(CityCatalog::RESERVED).to include("maintenance", "maintenance-api")
    expect(CityDatabase.valid_slug?("maintenance")).to be(false)
    expect(CityDatabase.valid_slug?("maintenance-api")).to be(false)
  end

  it "resolves no city on either host" do
    expect(CityCatalog.find_by_host("maintenance-api.rotasaude.app")).to be_nil
    expect(CityCatalog.find_by_host("maintenance.rotasaude.app")).to be_nil
  end

  it "matches the API host only" do
    expect(CityCatalog.maintenance_api_host?("maintenance-api.rotasaude.app")).to be(true)
    expect(CityCatalog.maintenance_api_host?("maintenance.rotasaude.app")).to be(false)
    expect(CityCatalog.maintenance_api_host?("admin.rotasaude.app")).to be(false)
    expect(CityCatalog.maintenance_api_host?("curitiba.rotasaude.app")).to be(false)
  end

  it "matches requests through the route constraint" do
    request = ActionDispatch::TestRequest.create("HTTP_HOST" => "maintenance-api.rotasaude.app")
    other   = ActionDispatch::TestRequest.create("HTTP_HOST" => "admin.rotasaude.app")

    expect(MaintenanceApiHost.matches?(request)).to be(true)
    expect(MaintenanceApiHost.matches?(other)).to be(false)
  end
end
