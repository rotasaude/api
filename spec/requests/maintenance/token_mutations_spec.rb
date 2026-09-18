require "rails_helper"

# Spec §7: o token é criado por PESSOA, com TOTP na hora, o segredo volta uma
# única vez e a listagem carrega só metadado. Revogar vale na hora.
RSpec.describe "Maintenance token mutations", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "tm-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def totp = ROTP::TOTP.new(maintainer.otp_secret).now

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: totp }, headers: browser
    expect(response).to have_http_status(:ok)
  end

  def gql!(query, headers: browser, **variables)
    post "/graphql", params: { query: query, variables: variables }, headers: headers
  end

  CREATE = <<~GQL
    mutation($name: String!, $access: String!, $expiresAt: ISO8601DateTime!, $code: String!, $citySlugs: [String!]) {
      createMaintenanceToken(name: $name, access: $access, expiresAt: $expiresAt, code: $code, citySlugs: $citySlugs) {
        ok
        secretOnce
        errors { path message }
      }
    }
  GQL

  REVOKE = <<~GQL
    mutation($id: ID!) { revokeMaintenanceToken(id: $id) { ok errors { path message } } }
  GQL

  LIST = <<~GQL
    { maintenanceTokens { id name access citySlugs expiresAt lastUsedAt revokedAt } }
  GQL

  def create_token!(name: "ci", access: "read_write", code: nil, expires_at: 30.days.from_now, city_slugs: [])
    gql!(CREATE, name: name, access: access, code: code || totp,
                 expiresAt: expires_at.iso8601, citySlugs: city_slugs)
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    # I3: o código do login é CONSUMIDO. O login acontece um minuto atrás para
    # que os exemplos tenham um passo de TOTP novo para o step-up — que é
    # exatamente o que a correção exige de quem usa a API de verdade.
    travel_to(1.minute.ago) { login! }
  end

  it "creates a token with a fresh TOTP, returning the secret exactly once" do
    create_token!

    payload = json.dig("data", "createMaintenanceToken")
    expect(payload["ok"]).to be(true)
    expect(payload["errors"]).to be_empty
    expect(payload["secretOnce"]).to start_with(MaintenanceToken.prefix)

    token = MaintenanceToken.sole
    expect(token.token_digest).to eq(MaintenanceToken.digest_for(payload["secretOnce"]))
    expect(token.maintainer_id).to eq(maintainer.id)

    events = PlatformEvent.where(name: "maintenance.token.created").last(2)
    expect(events.map { |e| e.payload["outcome"] }).to eq(%w[attempted ok])
    expect(events.map { |e| e.payload["correlation_id"] }.uniq.size).to eq(1)
    expect(events.last.payload).to include("token_label" => "ci", "module" => "token")
  end

  it "refuses a wrong TOTP as a user error, creating nothing and auditing the rejection" do
    create_token!(code: "000000")

    payload = json.dig("data", "createMaintenanceToken")
    expect(payload["ok"]).to be(false)
    expect(payload["secretOnce"]).to be_nil
    expect(payload["errors"].first).to include("path" => "code")
    expect(MaintenanceToken.count).to eq(0)
    expect(PlatformEvent.where(name: "maintenance.token.created").last.payload["outcome"]).to eq("rejected")
  end

  it "refuses an expiry beyond the ceiling and an unknown access level" do
    create_token!(expires_at: MaintenanceToken::MAX_TTL.from_now + 1.day)
    expect(json.dig("data", "createMaintenanceToken", "ok")).to be(false)
    expect(json.dig("data", "createMaintenanceToken", "errors").first["path"]).to eq("expiresAt")

    # Passo de TOTP novo: o da chamada acima já foi consumido (I3).
    travel(31.seconds) do
      create_token!(access: "admin")
      expect(json.dig("data", "createMaintenanceToken", "ok")).to be(false)
      expect(MaintenanceToken.count).to eq(0)
    end
  end

  # I3 (fix round 2): o código que acabou de verificar a sessão no navegador
  # NÃO emite, segundos depois, uma credencial de 90 dias.
  it "refuses the very TOTP code that opened the session" do
    reset!
    host! "maintenance-api.rotasaude.app"
    code = totp

    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: code }, headers: browser
    expect(response).to have_http_status(:ok)

    create_token!(code: code)

    expect(json.dig("data", "createMaintenanceToken", "ok")).to be(false)
    expect(json.dig("data", "createMaintenanceToken", "errors").first["path"]).to eq("code")
    expect(MaintenanceToken.count).to eq(0)
  end

  # C2 (fix round 2): o step-up não tinha bloqueio nem teto. Uma sessão
  # sequestrada podia adivinhar o TOTP à vontade — e a tolerância de relógio
  # deixa ~3 códigos válidos ao mesmo tempo — até emitir uma credencial de 90
  # dias, que sobrevive a toda a limitação de tempo da sessão de onde saiu.
  it "counts a failed step-up toward the account lockout and audits it" do
    expect { create_token!(code: "000000") }
      .to change { PlatformEvent.where(name: "maintenance.session.failed").count }.by(1)

    expect(maintainer.reload.failed_attempts).to eq(1)
    expect(PlatformEvent.where(name: "maintenance.session.failed").last.payload)
      .to include("credential" => { "kind" => "totp" }, "maintainer_id" => maintainer.id)
  end

  it "locks the account after five failed step-ups, and then refuses even the right code" do
    Maintainer::LOCKOUT_ATTEMPTS.times { create_token!(code: "000000") }

    expect(maintainer.reload.locked?).to be(true)
    expect(PlatformEvent.where(name: "maintenance.session.locked").count).to eq(1)

    create_token!

    expect(json.dig("data", "createMaintenanceToken", "ok")).to be(false)
    expect(json.dig("data", "createMaintenanceToken", "errors").first["path"]).to eq("code")
    expect(MaintenanceToken.count).to eq(0)
  end

  it "lists metadata only — never the secret, on this or any later request" do
    create_token!
    secret = json.dig("data", "createMaintenanceToken", "secretOnce")

    gql!(LIST)

    listed = json.dig("data", "maintenanceTokens").sole
    expect(listed.keys).to contain_exactly(*%w[id name access citySlugs expiresAt lastUsedAt revokedAt])
    expect(response.body).not_to include(secret)
    expect(response.body).not_to include(MaintenanceToken.sole.token_digest)
  end

  it "revokes a token, and the revoked secret stops authenticating" do
    create_token!
    secret = json.dig("data", "createMaintenanceToken", "secretOnce")
    token = MaintenanceToken.sole

    gql!(REVOKE, id: token.id)

    expect(json.dig("data", "revokeMaintenanceToken", "ok")).to be(true)
    expect(token.reload.revoked_at).to be_present
    expect(PlatformEvent.where(name: "maintenance.token.revoked").last.payload["outcome"]).to eq("ok")

    post "/graphql", params: { query: "{ me { id } }" }, headers: { "Authorization" => "Bearer #{secret}" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "answers a user error, not a crash, for an unknown token id" do
    gql!(REVOKE, id: SecureRandom.uuid)

    expect(json.dig("data", "revokeMaintenanceToken", "ok")).to be(false)
    expect(json.dig("data", "revokeMaintenanceToken", "errors").first["path"]).to eq("id")
  end

  # A recusa vem do analisador da Task 5. Enquanto ela não estiver aplicada este
  # exemplo falha — é o RED que a Task 5 fecha; não o marque pending.
  it "never lets a token manage tokens, whatever its access level" do
    _record, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                                              city_slugs: [], expires_at: 10.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}" }
    # `login!` no `before` já deixou o cookie de sessão neste client de teste;
    # um bearer real nunca chega com cookie junto (spec §7: cookie OU bearer,
    # nunca os dois — `resolve_maintenance_credential` recusa como
    # ambiguous_credentials antes até de chegar no GraphQL). `reset!` zera o
    # client de teste (cookie incluso) para exercitar o token sozinho.
    reset!
    host! "maintenance-api.rotasaude.app"

    post "/graphql", params: { query: CREATE, variables: { name: "outro", access: "read",
                                                           expiresAt: 5.days.from_now.iso8601, code: totp,
                                                           citySlugs: [] } }, headers: bearer
    expect(json["errors"]).to be_present
    expect(json.dig("data", "createMaintenanceToken")).to be_nil

    post "/graphql", params: { query: LIST }, headers: bearer
    expect(json["errors"]).to be_present

    expect(MaintenanceToken.count).to eq(1)
  end
end
