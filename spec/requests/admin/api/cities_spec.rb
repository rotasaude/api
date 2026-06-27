require "rails_helper"
require Rails.root.join("spec/support/admin_rls")
require Rails.root.join("spec/support/admin_auth")

RSpec.describe "Admin::Api::Cities", type: :request do
  # O controller usa with_admin_connection (BYPASSRLS cross-tenant); precisa da
  # conexão admin real — ver spec/support/admin_rls.
  self.use_transactional_tests = false

  before { clean_admin_tables }
  after  { clean_admin_tables }

  it "operador vê todas as cidades (cross-tenant)" do
    as_admin do
      Municipality.create!(name: "Alpha", slug: "alpha", uf: "SP", status: "active")
      Municipality.create!(name: "Bravo", slug: "bravo", uf: "RJ", status: "active")
    end
    sign_in_as(operator!)

    get "/admin/api/cities", params: { period: "7d" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    slugs = body.dig("data", "cities").map { |c| c["slug"] }
    expect(slugs).to contain_exactly("alpha", "bravo")
    expect(body["as_of"]).to be_present
  end

  it "nega acesso a não-operador" do
    user = User.create!(email_address: "muni@local", password: "secret123")
    sign_in_as(user)

    get "/admin/api/cities", params: { period: "7d" }

    expect(response).to have_http_status(:forbidden)
  end

  it "exige autenticação" do
    get "/admin/api/cities", params: { period: "7d" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "show devolve recursos, kpis e timeline da cidade" do
    muni = as_admin do
      m = Municipality.create!(name: "Alpha", slug: "alpha", uf: "SP", status: "active")
      DomainEvent.create!(municipality_id: m.id, name: "triage.started", payload: {}, occurred_at: 1.hour.ago)
      m
    end
    sign_in_as(operator!)

    get "/admin/api/cities/#{muni.id}", params: { period: "7d" }

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["city"]["slug"]).to eq("alpha")
    expect(data).to have_key("resources")
    expect(data["kpis"]).to be_an(Array)
    expect(data["timeline"].first["type"]).to eq("triage.started")
  end

  it "show retorna 404 para cidade inexistente" do
    sign_in_as(operator!)
    get "/admin/api/cities/00000000-0000-0000-0000-000000000000", params: { period: "7d" }
    expect(response).to have_http_status(:not_found)
  end
end
