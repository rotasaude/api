require "rails_helper"

# CSRF na API da cidade (fix final do Plano 2 das assinaturas, I1). O cookie de
# sessão é SameSite=Lax e as cidades dividem um domínio registrável: um form num
# host irmão manda o cookie. Escrita autenticada por cookie só aceita
# `application/json` — o que um form ou um fetch no-cors não conseguem enviar
# sem preflight, e o preflight não dá credenciais a /protocols/* nem a /setup/*.
# Ver Authentication#require_json_for_cookie_writes.
RSpec.describe "Cookie-authenticated writes require JSON", type: :request do
  def json = JSON.parse(response.body)

  def enrolled_user(email:, role:)
    u = User.create!(email_address: email, password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    Membership.create!(user: u, role: role, granted_at: Time.current)
    u
  end

  def sign_in_stepped_up!(user)
    sign_in_as(user).tap { |s| s.update!(mfa_verified_at: Time.current) }
  end

  let!(:admin)     { enrolled_user(email: "admin@example.org", role: "municipal_admin") }
  let!(:publisher) { enrolled_user(email: "pub@example.org", role: "protocol_publisher") }
  let!(:ana)       { enrolled_user(email: "ana@example.org", role: "protocol_reviewer") }
  let!(:bia)       { enrolled_user(email: "bia@example.org", role: "protocol_reviewer") }

  # dengue v1 active (linha-base) e v2 ativada por assinatura: há o que reverter.
  def revertible_protocol!
    legacy = ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", activated_at: 3.days.ago,
                                        definition: protocol_definition_hash)
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil, created_at: 3.days.ago)
    v2 = ProtocolDefinition.create!(name: "dengue", version: 2, status: "published",
                                    definition: protocol_definition_hash(version: 2))
    sign!(v2, purpose: "activation", by: ana)
    sign!(v2, purpose: "activation", by: bia)
    expect(Protocols::Activate.call(version: 2, name: "dengue", by: publisher)).to be_ok
    [ legacy, v2 ]
  end

  # O que um form (ou fetch no-cors) de um host irmão consegue mandar: form
  # urlencoded, ou text/plain com um corpo que PARECE JSON.
  def forged_post(path, body_hash, kind)
    content_type, body = case kind
                         when "form" then [ "application/x-www-form-urlencoded", URI.encode_www_form(body_hash) ]
                         when "text/plain" then [ "text/plain", body_hash.to_json ]
                         end
    post path, params: body, headers: { "CONTENT_TYPE" => content_type }
  end

  %w[form text/plain].each do |kind|
    context "a #{kind} POST with a valid session" do
      it "POST /protocols/revert: 415 json_required, the active version does not change" do
        _legacy, v2 = revertible_protocol!
        sign_in_stepped_up!(publisher)

        expect {
          forged_post("/protocols/revert", { name: "dengue", reason: "forjado" }, kind)
        }.not_to change(ProtocolActivation, :count)

        expect(response).to have_http_status(:unsupported_media_type)
        expect(json).to eq("error" => "json_required")
        expect(v2.reload.status).to eq("active")
      end

      it "POST /setup/memberships: 415 json_required, no membership is created" do
        sign_in_as(admin)

        expect {
          forged_post("/setup/memberships", { user_id: publisher.id, role: "protocol_reviewer" }, kind)
        }.not_to change(Membership, :count)

        expect(response).to have_http_status(:unsupported_media_type)
        expect(json).to eq("error" => "json_required")
        expect(publisher.reload.has_role?(:protocol_reviewer)).to be(false)
      end

      it "POST /setup/invitations: 415 json_required, no invitation is created" do
        sign_in_as(admin)

        expect {
          forged_post("/setup/invitations", { email: "evil@example.org", role: "municipal_admin" }, kind)
        }.not_to change(Invitation, :count)

        expect(response).to have_http_status(:unsupported_media_type)
        expect(json).to eq("error" => "json_required")
      end
    end
  end

  it "a body-less POST with the parameters in the query string is refused too" do
    sign_in_as(admin)

    expect {
      post "/setup/memberships?user_id=#{publisher.id}&role=protocol_reviewer"
    }.not_to change(Membership, :count)

    expect(response).to have_http_status(:unsupported_media_type)
    expect(json).to eq("error" => "json_required")
  end

  context "the same requests as JSON" do
    it "POST /protocols/revert reverts" do
      legacy, v2 = revertible_protocol!
      sign_in_stepped_up!(publisher)

      post "/protocols/revert", params: { name: "dengue", reason: "v2 erra a prioridade" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(legacy.reload.status).to eq("active")
      expect(v2.reload.status).to eq("published")
    end

    it "POST /setup/memberships grants the role" do
      sign_in_as(admin)

      post "/setup/memberships", params: { user_id: publisher.id, role: "protocol_reviewer" }, as: :json

      expect(response).to have_http_status(:created)
      expect(publisher.reload.has_role?(:protocol_reviewer)).to be(true)
    end

    it "POST /setup/invitations invites (a charset parameter is fine)" do
      sign_in_as(admin)

      expect {
        post "/setup/invitations", params: { email: "nova@example.org", role: "viewer" }.to_json,
                                   headers: { "CONTENT_TYPE" => "application/json; charset=utf-8" }
      }.to change(Invitation, :count).by(1)

      expect(response).to have_http_status(:created)
    end
  end

  it "a form POST without a session still gets 401 unauthenticated, not 415" do
    forged_post("/setup/memberships", { user_id: publisher.id, role: "protocol_reviewer" }, "form")

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "unauthenticated")
  end

  it "a public write without a session cookie keeps accepting a form body (login)" do
    post "/session", params: { email_address: "pub@example.org", password: "secret123" }

    expect(response).to have_http_status(:created)
  end

  it "logout (DELETE /session with no body, as both frontends send it) still works" do
    session = sign_in_as(admin)

    delete "/session"

    expect(response).to have_http_status(:no_content)
    expect(Session.exists?(session.id)).to be(false)
  end
end
