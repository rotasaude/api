require "rails_helper"

# api#35 passo 3 (contract): memberships da sessão e envelope de /admin/api só
# emitem as chaves city_* / city; os aliases municipality_* / municipality
# foram removidos.
RSpec.describe "Chaves city_* (contract, api#35)", type: :request do
  let(:viewer) { staff_with("viewer@cidade.gov.br", "viewer") }
  let(:city) { Current.city }

  before { sign_in_as(viewer) }

  it "GET /session: cada membership traz city_slug/name/uf e nenhuma municipality_*" do
    get "/session", as: :json
    expect(response).to have_http_status(:ok)
    membership = JSON.parse(response.body).fetch("memberships").first

    expect(membership).to include("city_slug" => city.slug, "city_name" => city.name, "city_uf" => city.uf)
    expect(membership.keys.grep(/municipality/)).to be_empty
  end

  it "GET /admin/api/overview: scope.city {slug,name,uf} e sem scope.municipality" do
    get "/admin/api/overview", params: { period: "7d" }
    expect(response).to have_http_status(:ok)
    scope = JSON.parse(response.body).dig("data", "scope")

    expect(scope["city"]).to eq("slug" => city.slug, "name" => city.name, "uf" => city.uf)
    expect(scope).not_to have_key("municipality")
  end
end
