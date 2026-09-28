require "rails_helper"

RSpec.describe "Filtro de bairro em /admin/api", type: :request do
  def body = JSON.parse(response.body)

  panels = %w[overview classification triages reports conversations]

  let(:viewer) { staff_with("viewer@cidade.gov.br", "viewer") }
  let!(:antigo) { Neighborhood.create!(name: "Ahu", source: "seed", active: false) }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }

  before { sign_in_as(viewer) }

  panels.each do |panel|
    describe "/admin/api/#{panel}" do
      it "sem parâmetro: filter null; com bairro (mesmo inativo): {id, name}; none: \"none\"" do
        get "/admin/api/#{panel}", params: { period: "7d" }
        expect(response).to have_http_status(:ok)
        expect(body.dig("data", "filter")).to eq("neighborhood" => nil)
        expect(body.dig("data", "scope")).to be_present

        get "/admin/api/#{panel}", params: { period: "7d", neighborhood_id: antigo.id }
        expect(body.dig("data", "filter")).to eq("neighborhood" => { "id" => antigo.id, "name" => "Ahu" })

        get "/admin/api/#{panel}", params: { period: "7d", neighborhood_id: "none" }
        expect(body.dig("data", "filter")).to eq("neighborhood" => "none")
      end

      it "parâmetro inválido (não UUID, UUID inexistente, lista): 422 invalid_neighborhood" do
        [ "abc", SecureRandom.uuid, [ centro.id ] ].each do |raw|
          get "/admin/api/#{panel}", params: { period: "7d", neighborhood_id: raw }
          expect(response).to have_http_status(:unprocessable_entity), raw.inspect
          expect(body).to eq("error" => "invalid_neighborhood")
        end
      end
    end
  end

  it "o resto de /admin/api ignora o parâmetro" do
    get "/admin/api/events", params: { period: "7d", neighborhood_id: "abc" }
    expect(response).to have_http_status(:ok)
    expect(body["data"]).not_to have_key("filter")
  end

  describe "GET /admin/api/neighborhoods" do
    let(:expected) do
      { "neighborhoods" => [ { "id" => antigo.id, "name" => "Ahu", "active" => false },
                             { "id" => centro.id, "name" => "Centro", "active" => true } ] }
    end

    Membership::ROLES.each do |role|
      it "#{role}: todos, inativos marcados, por nome, sem envelope" do
        sign_in_as(staff_with("#{role}-nb@cidade.gov.br", role))
        get "/admin/api/neighborhoods"
        expect(response).to have_http_status(:ok)
        expect(body).to eq(expected)
      end
    end

    it "usuário sem vínculo ativo na cidade: 403 no_city_membership (mesma regra dos painéis)" do
      sign_in_as(User.create!(email_address: "sem-vinculo@cidade.gov.br", password: "senha-segura-123"))
      get "/admin/api/neighborhoods"
      expect(response).to have_http_status(:forbidden)
      expect(body).to eq("error" => "no_city_membership")
    end
  end

  it "GET /admin/api/neighborhoods sem sessão: 401" do
    # cookies aqui é Rack::Test::CookieJar (não ActionDispatch::Cookies): seu
    # #delete compara cookie.name (String) por == com o argumento sem
    # conversão, então um Symbol nunca casa e vira no-op — precisa de String.
    cookies.delete("session_id")
    get "/admin/api/neighborhoods"
    expect(response).to have_http_status(:unauthorized)
  end
end
