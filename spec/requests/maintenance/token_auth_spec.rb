require "rails_helper"

# Spec §7: automação autentica por bearer, sem cookie e sem CORS. Cookie e
# bearer juntos são recusados: não pode haver dúvida sobre quem agiu.
RSpec.describe "Maintenance token authentication", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "ta-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:issued) do
    MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                            city_slugs: [], expires_at: 10.days.from_now)
  end
  let(:token) { issued.first }
  let(:secret) { issued.last }

  def json = JSON.parse(response.body)
  def bearer(value = secret) = { "Authorization" => "Bearer #{value}" }
  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def query!(headers) = post("/graphql", params: { query: "{ me { id } }" }, headers: headers)

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
  end

  it "authenticates a token without Origin, header or cookie" do
    query!(bearer)

    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "me", "id")).to eq(maintainer.id)
    expect(token.reload.last_used_at).to be_present
  end

  it "refuses a cookie and a bearer in the same request" do
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser

    query!(browser.merge(bearer))

    expect(response).to have_http_status(:unauthorized)
    expect(json).to include("error" => "ambiguous_credentials")
  end

  it "refuses an expired, revoked, unknown or foreign-environment token, and audits the refusal" do
    query!(bearer("#{MaintenanceToken.prefix}nao-existe"))
    expect(response).to have_http_status(:unauthorized)

    token.revoke!
    query!(bearer)
    expect(response).to have_http_status(:unauthorized)

    expect(PlatformEvent.where(name: "maintenance.token.refused").count).to eq(2)
    expect(PlatformEvent.where(name: "maintenance.token.refused").last.payload).to include("outcome" => "rejected")
  end

  it "refuses a token whose owner was deactivated" do
    Maintainer.create!(email_address: "second-#{SecureRandom.hex(3)}@rotasaude.app") # último ativo não desativa (Plano 3)
    maintainer.deactivate!

    query!(bearer)

    expect(response).to have_http_status(:unauthorized)
  end

  it "keeps the browser path unchanged: no bearer means Origin and header are still required" do
    query!({ "Origin" => "https://attacker.example", "X-Rota-Maintenance" => "1" })

    expect(response).to have_http_status(:forbidden)
  end

  # Fix round 1 (Critical): um segredo recusado sem o formato conhecido não
  # pode virar dado gravado na auditoria — nem inteiro, nem em pedaço.
  #
  # Fix round 2 (C1): agora ele não vira gravação NENHUMA. Uma enxurrada de
  # bearers de outro formato — o que um prober manda — não escreve uma linha
  # sequer em platform_events, onde o trigger de `maintenance.%` impede apagar
  # depois. O prefixo deste ambiente continua sendo o que separa "alguém
  # insistindo com um segredo do formato certo" de ruído.
  it "writes no audit row for a flood of bearers without this environment prefix" do
    garbage = "nounderscoreshere"
    refused = PlatformEvent.where(name: "maintenance.token.refused")

    expect {
      query!(bearer(garbage))
      5.times { |i| query!(bearer("rsm_other_#{i}")) }
      query!(bearer("rsm_stg_#{SecureRandom.hex(4)}"))
    }.not_to change { refused.count }

    expect(response).to have_http_status(:unauthorized)
  end

  it "still writes exactly one audit row for a refused bearer of this environment" do
    refused = PlatformEvent.where(name: "maintenance.token.refused")

    expect { query!(bearer("#{MaintenanceToken.prefix}nao-existe")) }.to change { refused.count }.by(1)

    expect(refused.last.payload).to include("token_prefix" => MaintenanceToken.prefix, "outcome" => "rejected")
  end

  # C1: o teto de requisições, que não existia em /graphql. O cache do ambiente
  # de teste é :null_store, que nunca conta — `rate_limit` recebe um store que
  # resolve `Rails.cache` a cada requisição justamente para que este exemplo
  # possa trocá-lo por um real.
  describe "rate limiting" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "caps the per-IP volume, and the cap comes BEFORE the refusal is audited" do
      limit = Maintenance::GraphqlController::IP_RATE
      refused = PlatformEvent.where(name: "maintenance.token.refused")

      expect {
        (limit + 3).times { query!(bearer("#{MaintenanceToken.prefix}nao-existe")) }
      }.to change { refused.count }.by(limit)

      expect(response).to have_http_status(:too_many_requests)
      expect(json).to eq({ "error" => "too_many_requests" })
    end

    # C1 (fix round 2, segunda passada): o teto de /graphql não cobria o resto
    # do host. `resolve_maintenance_credential` — que é quem AUDITA o bearer
    # recusado — roda em toda controller de manutenção, e `DELETE /session` não
    # tinha teto nenhum: um bearer de lixo com o prefixo certo, repetido ali,
    # continuava escrevendo uma linha indelével por requisição.
    it "caps the per-IP volume on a non-GraphQL route too, before the refusal is audited" do
      cap = MaintainerAuthentication::HOST_IP_RATE
      refused = PlatformEvent.where(name: "maintenance.token.refused")
      junk = bearer("#{MaintenanceToken.prefix}nao-existe")

      expect {
        (cap + 3).times { delete "/session", headers: junk }
      }.to change { refused.count }.by(cap)

      expect(response).to have_http_status(:too_many_requests)
      expect(json).to eq({ "error" => "too_many_requests" })
    end

    # O teto do host é de fora e largo: um navegador de verdade não o sente. O
    # `rate_limit to: 10, within: 3.minutes` de /session segue valendo por cima
    # dele, inalterado.
    it "does not throttle a normal browser login flow" do
      post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
      post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
           headers: browser
      expect(response).to have_http_status(:ok)

      get "/session", headers: browser
      expect(response).to have_http_status(:ok)

      delete "/session", headers: browser
      expect(response).to have_http_status(:no_content)
    end

    it "caps the per-token volume below the per-IP one, so the token cap can fire" do
      limit = Maintenance::GraphqlController::TOKEN_RATE
      expect(limit).to be < Maintenance::GraphqlController::IP_RATE

      limit.times { query!(bearer) }
      expect(response).to have_http_status(:ok)

      query!(bearer)
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  # I4: `last_used_at` respondia "este token ainda é usado?" ao preço de uma
  # ESCRITA por requisição autenticada.
  it "stamps last_used_at once per window, not once per request" do
    query!(bearer)
    first = token.reload.last_used_at
    expect(first).to be_present

    query!(bearer)
    expect(token.reload.last_used_at).to eq(first)

    travel(MaintenanceToken::TOUCH_WINDOW + 1.minute) do
      query!(bearer)
      expect(token.reload.last_used_at).to be > first
    end
  end

  # I1 (fix round 2, spec §9): "uso recusado de token … fora do escopo" não
  # deixava rastro nenhum. Um token batendo em `auditEvents` ou em mutation é
  # recusado pelos analisadores ANTES de qualquer resolver, e era justamente
  # essa recusa — o padrão que denuncia credencial vazada — que sumia.
  describe "a token refused by the analyzers" do
    def read_token
      MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                              city_slugs: [], expires_at: 10.days.from_now).last
    end

    it "audits the refusal with the token id and the refused field names" do
      refused = PlatformEvent.where(name: "maintenance.token.refused")

      expect {
        post "/graphql", params: { query: "{ auditEvents { name } }" }, headers: bearer
      }.to change { refused.count }.by(1)

      expect(json["errors"]).to be_present
      event = refused.last.payload
      expect(event).to include("outcome" => "rejected", "module" => "token",
                               "maintainer_id" => maintainer.id,
                               "refused_fields" => [ "auditEvents" ],
                               "credential" => { "kind" => "token", "token_id" => token.id })
      expect(event["request_id"]).to be_present
      expect(event["ip"]).to be_present
    end

    it "audits a read token refused by the write scope, naming the mutation it tried" do
      secret = read_token
      mutation = <<~GQL
        mutation { inviteMaintainer(emailAddress: "x@rotasaude.app", code: "000000") { ok } }
      GQL
      refused = PlatformEvent.where(name: "maintenance.token.refused")

      expect {
        post "/graphql", params: { query: mutation }, headers: bearer(secret)
      }.to change { refused.count }.by(1)

      expect(refused.last.payload["refused_fields"]).to include("inviteMaintainer")
      expect(Maintainer.find_by(email_address: "x@rotasaude.app")).to be_nil
    end

    it "writes nothing when the token asks for what it may have" do
      refused = PlatformEvent.where(name: "maintenance.token.refused")

      expect { query!(bearer) }.not_to change { refused.count }
      expect(response).to have_http_status(:ok)
    end

    # O segredo nunca entra no evento — nem o apresentado, nem o gravado.
    it "never puts a secret in the refusal payload" do
      post "/graphql", params: { query: "{ auditEvents { name } }" }, headers: bearer

      payload = PlatformEvent.where(name: "maintenance.token.refused").last.payload.to_json
      expect(payload).not_to include(secret)
      expect(payload).not_to include(token.token_digest)
    end
  end

  # I5 (spec §9): `request_id` e `ip` fazem parte do payload e não chegavam ao
  # evento — são o que liga a linha da trilha à requisição no log.
  it "carries request_id and ip on a refused bearer of this environment" do
    query!(bearer("#{MaintenanceToken.prefix}nao-existe"))

    payload = PlatformEvent.where(name: "maintenance.token.refused").last.payload
    expect(payload["request_id"]).to be_present
    expect(payload["ip"]).to eq("127.0.0.1")
  end

  # Fix round 1 (I3): /session é do navegador. Um bearer não vira sessão ali —
  # nem para ler, nem para encerrar.
  it "refuses a bearer-authenticated GET /session" do
    get "/session", headers: bearer

    expect(response).to have_http_status(:forbidden)
    expect(json).to eq({ "error" => "browser_only" })
  end

  it "refuses a bearer-authenticated DELETE /session" do
    delete "/session", headers: bearer

    expect(response).to have_http_status(:forbidden)
    expect(json).to eq({ "error" => "browser_only" })
  end

  # M7 (fix round 2): /invitations nunca ganhou a trava que /session tem. Um
  # bearer era aceito ali — e, por ser token, ainda pulava a checagem de
  # Origin. São os endpoints que DEFINEM senha e TOTP de um superusuário.
  it "refuses a bearer on the invitation endpoints, which are browser-only too" do
    invitation, invitation_token = MaintainerInvitation.issue!(maintainer: maintainer)

    post "/invitations/enroll", params: { token: invitation_token }, headers: bearer
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq({ "error" => "browser_only" })

    post "/invitations/accept", params: { token: invitation_token, password: "s3nha-forte-nova",
                                          code: "000000" }, headers: bearer
    expect(response).to have_http_status(:forbidden)

    expect(invitation.reload.used_at).to be_nil
    expect(maintainer.reload.otp_secret).to be_present
  end
end
