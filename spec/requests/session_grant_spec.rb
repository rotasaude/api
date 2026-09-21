require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)

# A cidade consome o grant (Plano 3B) e abre a Session local. Operador: sessão só
# leitura, auditada na plataforma E na cidade. Usuário: sessão normal da cidade
# (é o que o callback do gov.br emite, Task 4).
RSpec.describe "POST /session/grant", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }

  def json = JSON.parse(response.body)
  def set_cookie_header = Array(response.headers["Set-Cookie"]).join("\n")
  def operator_grant(for_city: city) = CityGrants.issue(city: for_city, kind: "operator", subject_id: operator.id)

  it "opens a read-only operator session, audited on the platform and in the city" do
    token = operator_grant

    expect {
      post "/session/grant", params: { token: token }, as: :json
    }.to change(Session, :count).by(1)
      .and change { PlatformEvent.where(name: "operator.city_access").count }.by(1)
      .and change { DomainEvent.where(name: "operator.city_access").count }.by(1)

    expect(response).to have_http_status(:created)
    expect(json).to include("id" => operator.id, "operator" => true, "memberships" => [])
    session = Session.order(:created_at).last
    expect(session).to have_attributes(operator_id: operator.id, user_id: nil)
    expect(PlatformEvent.where(name: "operator.city_access").last.payload)
      .to eq("city_id" => city.id, "operator_id" => operator.id)
    expect(DomainEvent.where(name: "operator.city_access").last.payload)
      .to include("operator_id" => operator.id, "session_id" => session.id)
    expect(set_cookie_header).to match(/session_id=/)
    expect(set_cookie_header).not_to match(/domain=/i)

    get "/admin/api/reports", params: { period: "30d" }
    expect(response).to have_http_status(:ok)
    post "/setup/invitations", params: { email: "x@x.com", role: "viewer" }
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "operator_read_only")
  end

  it "works end to end from the console grant to the city session" do
    host! "admin.rotasaude.app"
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    post "/city_grants", params: { city_slug: city.slug }
    token = Rack::Utils.parse_query(URI.parse(json["redirect_url"]).query).fetch("grant")

    host! test_city_host
    post "/session/grant", params: { token: token }, as: :json

    expect(response).to have_http_status(:created)
    expect(json["operator"]).to be(true)
  end

  it "refuses a grant used a second time" do
    token = operator_grant
    post "/session/grant", params: { token: token }, as: :json

    expect {
      post "/session/grant", params: { token: token }, as: :json
    }.not_to change(Session, :count)
    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_grant")
  end

  it "refuses a grant issued for another city without consuming it" do
    other = create(:city, slug: TEST_CITY_B.slug, status: "active", database_url: city_database_url("rota_saude_test_city_b"))
    token = operator_grant(for_city: other)

    post "/session/grant", params: { token: token }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(CityGrant.order(:created_at).last.consumed_at).to be_nil
  end

  it "refuses an expired grant" do
    token = operator_grant

    travel 61.seconds do
      post "/session/grant", params: { token: token }, as: :json
    end

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an operator deactivated after the grant was issued, with no session and no audit" do
    token = operator_grant
    operator.update!(deactivated_at: Time.current)

    expect {
      post "/session/grant", params: { token: token }, as: :json
    }.to not_change(Session, :count).and not_change(PlatformEvent, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it "opens no session when the platform audit fails" do
    token = operator_grant
    allow(Platform).to receive(:audit).and_raise(ActiveRecord::StatementInvalid, "boom")

    expect {
      post "/session/grant", params: { token: token }, as: :json
    }.to raise_error(ActiveRecord::StatementInvalid).and not_change(Session, :count)
  end

  it "opens a normal session for a user grant of this city" do
    user = User.create!(email_address: "u-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    token = CityGrants.issue(city: city, kind: "user", subject_id: user.id)

    post "/session/grant", params: { token: token }, as: :json

    expect(response).to have_http_status(:created)
    expect(json).to include("id" => user.id, "operator" => false)
    expect(Session.order(:created_at).last).to have_attributes(user_id: user.id, operator_id: nil)
  end

  it "refuses a user grant whose user does not exist in this city" do
    token = CityGrants.issue(city: city, kind: "user", subject_id: SecureRandom.uuid)

    post "/session/grant", params: { token: token }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_grant")
  end

  it "destroys the previous session when a grant is redeemed, replacing it with the new one" do
    user = User.create!(email_address: "u-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    old_session = sign_in_as(user)
    token = operator_grant

    post "/session/grant", params: { token: token }, as: :json

    expect(response).to have_http_status(:created)
    expect(Session.exists?(old_session.id)).to be(false)

    get "/session"
    expect(response).to have_http_status(:ok)
    expect(json).to include("id" => operator.id, "operator" => true)
  end

  it "refuses a malformed or non-string token" do
    [ "lixo", [ "lixo" ], nil ].each do |token|
      post "/session/grant", params: { token: token }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
