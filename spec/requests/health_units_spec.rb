require "rails_helper"

RSpec.describe "Health units", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:admin) { user_with("admin@cidade.gov.br", "municipal_admin") }
  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  def body = JSON.parse(response.body)

  def user_with(email, role)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: role, granted_at: Time.current)
    end
  end

  it "admin cria, edita, desativa e reativa" do
    sign_in_as(admin)

    json_post "/attendance/units", name: "UBS Centro", kind: "ubs"
    expect(response).to have_http_status(:created)
    id = body.dig("unit", "id")
    expect(body["unit"]).to include("name" => "UBS Centro", "kind" => "ubs", "active" => true)

    json_post "/attendance/units/#{id}", name: "UBS Centro Renomeada", kind: "upa"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]).to include("name" => "UBS Centro Renomeada", "kind" => "upa")

    json_post "/attendance/units/#{id}/deactivate"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["active"]).to be(false)

    json_post "/attendance/units/#{id}/activate"
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["active"]).to be(true)
  end

  it "nome repetido em outra caixa: 422 unit_name_taken" do
    create_unit("UBS Centro")
    sign_in_as(admin)
    json_post "/attendance/units", name: "ubs centro", kind: "ubs"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("unit_name_taken")
  end

  it "tipo desconhecido: 422 invalid_kind" do
    sign_in_as(admin)
    json_post "/attendance/units", name: "UBS Nova", kind: "clinica"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("invalid_kind")
  end

  it "atendente lista só ativas e recebe 403 nas escritas e em /units/all" do
    active = create_unit("UBS Ativa")
    create_unit("UBS Inativa", active: false)
    sign_in_as(verifier)

    get "/attendance/units"
    expect(response).to have_http_status(:ok)
    expect(body["units"].map { |u| u["id"] }).to eq([ active.id ])

    get "/attendance/units/all"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units", name: "UBS Nova", kind: "ubs"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}", name: "UBS Outra", kind: "ubs"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}/deactivate"
    expect(response).to have_http_status(:forbidden)

    json_post "/attendance/units/#{active.id}/activate"
    expect(response).to have_http_status(:forbidden)
  end
end
