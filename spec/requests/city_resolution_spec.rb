require "rails_helper"

RSpec.describe "City resolution", type: :request do
  before do
    City.delete_all
    CityCatalog.reset_cache!
  end

  # Controller de teste, montado só neste spec.
  before(:all) do
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      get "/_probe", to: "city_probe#show"
    end
  end

  after(:all) do
    Rails.application.routes.disable_clear_and_finalize = false
    Rails.application.reload_routes!
  end

  let(:city_a_url) { ENV.fetch("TEST_CITY_A_URL", city_database_url("rota_saude_test_city_a")) }

  it "serves an active city and exposes it on Current" do
    create(:city, slug: "cidadeviva", status: "active", database_url: city_a_url)
    get "/_probe", headers: { "HOST" => "cidadeviva.rotasaude.app" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include(
      "city" => "cidadeviva", "database" => "rota_saude_test_city_a"
    )
  end

  it "returns 404 for an unknown host" do
    get "/_probe", headers: { "HOST" => "inexistente.rotasaude.app" }
    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("unknown_city")
  end

  it "returns 403 for a suspended city" do
    create(:city, slug: "suspensa", status: "suspended", database_url: city_a_url)
    get "/_probe", headers: { "HOST" => "suspensa.rotasaude.app" }
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("city_suspended")
  end

  it "returns 404 for a city still provisioning" do
    create(:city, slug: "nascendo", status: "provisioning", database_url: city_a_url)
    get "/_probe", headers: { "HOST" => "nascendo.rotasaude.app" }
    expect(response).to have_http_status(:not_found)
    # "provisioning" and "does not exist" must be indistinguishable to the
    # client — leaking that a city is being set up is a security property,
    # not an oversight, so the body must match the unknown-host sibling exactly.
    expect(JSON.parse(response.body)["error"]).to eq("unknown_city")
  end

  it "returns 404 for an archived city" do
    create(:city, slug: "desligada", status: "archived", database_url: city_a_url)
    get "/_probe", headers: { "HOST" => "desligada.rotasaude.app" }
    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("unknown_city")
  end

  it "returns 404 for a reserved subdomain" do
    get "/_probe", headers: { "HOST" => "admin.rotasaude.app" }
    expect(response).to have_http_status(:not_found)
  end
end
