require "rails_helper"

# api#35 passo 1 (expand): memberships da sessão e envelope de /admin/api emitem
# as chaves city_* / city ao lado das municipality_* / municipality (aliases
# deprecados até o passo 3).
RSpec.describe "Chaves city_* (expand, api#35)", type: :request do
  let(:viewer) { staff_with("viewer@cidade.gov.br", "viewer") }
  let(:city) { Current.city }

  before { sign_in_as(viewer) }

  it "GET /session: cada membership traz city_slug/name/uf e mantém municipality_*" do
    get "/session", as: :json
    expect(response).to have_http_status(:ok)
    membership = JSON.parse(response.body).fetch("memberships").first

    expect(membership).to include(
      "city_slug" => city.slug, "city_name" => city.name, "city_uf" => city.uf,
      "municipality_id" => city.slug, "municipality_name" => city.name, "municipality_uf" => city.uf
    )
  end

  it "GET /admin/api/overview: scope.city {slug,name,uf} e scope.municipality preservado" do
    get "/admin/api/overview", params: { period: "7d" }
    expect(response).to have_http_status(:ok)
    scope = JSON.parse(response.body).dig("data", "scope")

    expect(scope["city"]).to eq("slug" => city.slug, "name" => city.name, "uf" => city.uf)
    expect(scope["municipality"]).to include("id" => city.slug, "slug" => city.slug, "uf" => city.uf)
  end
end
