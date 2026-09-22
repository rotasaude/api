require "rails_helper"

# A2 do final-fix-brief (2026-09-22-dashboard-signatures-03-protocolos): o
# painel de Eventos filtrava por `payload ->> 'name'`, mas os commands de
# Protocols publicam `protocol_key:` — o filtro nunca batia e a lista de
# nomes aceitos nem incluía os eventos de assinatura/ativação/reversão. Passa
# pelos endpoints HTTP de verdade (como spec/requests/protocol_lifecycle_spec.rb),
# nunca chamando os commands direto, para que CityResolution monte Current.city
# a partir do host — como em produção.
RSpec.describe "Admin protocols — events panel", type: :request do
  def json = JSON.parse(response.body)

  def enrolled_user(email:, role:)
    u = User.create!(email_address: email, password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    Membership.create!(user: u, role: role, granted_at: Time.current) if role
    u
  end

  def sign_in_stepped_up!(user)
    session = sign_in_as(user)
    session.update!(mfa_verified_at: Time.current)
    session
  end

  let!(:admin_user) { enrolled_user(email: "muadmin-#{SecureRandom.hex(3)}@example.org", role: "municipal_admin") }

  let!(:author)    { enrolled_user(email: "pauthor@example.org", role: "protocol_author") }
  let!(:ana)       { enrolled_user(email: "pana@example.org", role: "protocol_reviewer") }
  let!(:bia)       { enrolled_user(email: "pbia@example.org", role: "protocol_reviewer") }
  let!(:publisher) { enrolled_user(email: "ppub@example.org", role: "protocol_publisher") }

  def save_draft!(name:, version: 1, by: author)
    Protocols::SaveDraft.call(definition: protocol_definition_hash(name: name, version: version), by: by)
  end

  it "devolve submissão, assinatura e publicação em ordem decrescente de occurred_at" do
    save_draft!(name: "meningite")

    sign_in_as(author)
    post "/protocols/1/submit", params: { name: "meningite" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_stepped_up!(ana)
    post "/protocols/1/signatures", params: { name: "meningite", purpose: "publication" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_stepped_up!(bia)
    post "/protocols/1/signatures", params: { name: "meningite", purpose: "publication" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_stepped_up!(publisher)
    post "/protocols/1/publish", params: { name: "meningite" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_as(admin_user)
    get "/admin/api/protocols/meningite"
    expect(response).to have_http_status(:ok)

    names = json["data"]["events"].map { |e| e["name"] }
    expect(names).to include("protocol.submitted_for_review", "protocol.signed", "protocol.published")
    expect(names.count { |n| n == "protocol.signed" }).to eq(2)

    occurred_ats = json["data"]["events"].map { |e| Time.iso8601(e["at"]) }
    expect(occurred_ats).to eq(occurred_ats.sort.reverse)
  end

  it "inclui ativação e reversão nos nomes aceitos" do
    # Reversão só existe com uma ativação ANTERIOR à atual (mesma base da
    # spec de revertible em protocols_signatures_spec.rb): v1 já ativa como
    # linha-base, depois v2 sobe pelo fluxo real e é ativada por cima dela.
    legacy = ProtocolDefinition.create!(name: "coqueluche3", version: 1, status: "active",
                                        definition: protocol_definition_hash(name: "coqueluche3"))
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)

    save_draft!(name: "coqueluche3", version: 2)
    sign_in_as(author)
    post "/protocols/2/submit", params: { name: "coqueluche3" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_stepped_up!(ana)
    post "/protocols/2/signatures", params: { name: "coqueluche3", purpose: "publication" }, as: :json
    sign_in_stepped_up!(bia)
    post "/protocols/2/signatures", params: { name: "coqueluche3", purpose: "publication" }, as: :json
    sign_in_stepped_up!(publisher)
    post "/protocols/2/publish", params: { name: "coqueluche3" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_stepped_up!(ana)
    post "/protocols/2/signatures", params: { name: "coqueluche3", purpose: "activation" }, as: :json
    sign_in_stepped_up!(bia)
    post "/protocols/2/signatures", params: { name: "coqueluche3", purpose: "activation" }, as: :json
    sign_in_stepped_up!(publisher)
    post "/protocols/2/activate", params: { name: "coqueluche3" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_stepped_up!(admin_user)
    post "/protocols/revert", params: { name: "coqueluche3", reason: "teste A2" }, as: :json
    expect(response).to have_http_status(:ok)

    sign_in_as(admin_user)
    get "/admin/api/protocols/coqueluche3"

    names = json["data"]["events"].map { |e| e["name"] }
    expect(names).to include("protocol.activated", "protocol.activation_reverted")
  end
end
