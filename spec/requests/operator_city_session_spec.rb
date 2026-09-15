require "rails_helper"

# Operador dentro da cidade (grant, Plano 3B) é SÓ LEITURA — decisão do usuário.
# Negação por padrão: toda ação que não libera explicitamente a sessão de
# operador responde 403 operator_read_only.
RSpec.describe "Operator session inside a city", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end

  def json = JSON.parse(response.body)

  it "reads the city panels without any city membership" do
    sign_in_operator_grant(operator)

    # /admin/api/overview and /admin/api/queues read SolidQueue::* tables. Since
    # Plan 5 the city's queue lives in the city's database and CityConnection.with
    # routes SolidQueue::Record there too, so these panels read the city's own
    # queue.
    %w[/admin/api/overview /admin/api/queues /admin/api/reports /admin/api/triages].each do |path|
      get path, params: { period: "30d" }
      expect(response).to have_http_status(:ok), "#{path} respondeu #{response.status}"
    end
  end

  it "GET /session describes the operator, with no memberships" do
    sign_in_operator_grant(operator)

    get "/session"

    expect(response).to have_http_status(:ok)
    expect(json).to eq("id" => operator.id, "email_address" => operator.email_address, "mfa_enrolled" => true,
                       "operator" => true, "mfa_verified_at" => nil, "memberships" => [])
  end

  it "is refused on every action that is not explicitly read-only" do
    sign_in_operator_grant(operator)
    requests = [
      [ :post, "/setup/invitations", { email: "x@x.com", role: "viewer" } ],
      [ :get,  "/setup/memberships", {} ],
      [ :post, "/setup/users/#{SecureRandom.uuid}/deactivate", {} ],
      [ :post, "/setup/memberships/#{SecureRandom.uuid}/revoke", {} ],
      [ :post, "/mfa/enroll", {} ],
      [ :post, "/mfa/step_up", { code: "123456" } ],
      [ :get,  "/authoring/protocols/definition", { name: "x", version: 1 } ],
      [ :post, "/authoring/protocols/draft", { definition: { name: "x" } } ],
      [ :post, "/protocols/1/publish", {} ]
    ]

    requests.each do |verb, path, params|
      send(verb, path, params: params)
      expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} respondeu #{response.status}"
      expect(json).to eq("error" => "operator_read_only"), "#{verb.upcase} #{path} respondeu #{response.body}"
    end
  end

  it "logs out: DELETE /session destroys the operator session" do
    session = sign_in_operator_grant(operator)

    delete "/session"

    expect(response).to have_http_status(:no_content)
    expect(Session.exists?(session.id)).to be(false)
  end

  it "expires one hour after it was opened" do
    sign_in_operator_grant(operator)

    travel 61.minutes do
      get "/admin/api/reports", params: { period: "30d" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "stops working as soon as the operator is deactivated on the platform" do
    sign_in_operator_grant(operator)
    operator.update!(deactivated_at: Time.current)

    get "/admin/api/reports", params: { period: "30d" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "only exists in the city where it was opened" do
    sign_in_operator_grant(operator)
    create(:city, slug: TEST_CITY_B.slug, status: "active", database_url: city_database_url("rota_saude_test_city_b"))

    get "/admin/api/reports", params: { period: "30d" }, headers: { "HOST" => "#{TEST_CITY_B.slug}.rotasaude.app" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not change what a city user can do" do
    user = User.create!(email_address: "adm-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    sign_in_as(user)

    get "/setup/memberships"

    expect(response).to have_http_status(:ok)
  end
end
