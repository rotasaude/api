require "rails_helper"

# Parâmetros escalares (fix final do Plano 2 das assinaturas, I2).
# `params.require(:name)` aceitava `{"name":["A","B"]}`; em RevertActivation isso
# misturava o histórico de ativação de dois protocolos e terminava num
# RecordNotUnique (500). Array ou hash em name, purpose, reason, user_id ou role
# → 400 { error: "bad_request" }, antes do command. Ver ScalarParams.
RSpec.describe "Scalar protocol and role parameters", type: :request do
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

  def expect_bad_request(label)
    expect(response).to have_http_status(:bad_request), "#{label}: #{response.status} #{response.body}"
    expect(json).to eq("error" => "bad_request"), "#{label}: #{response.body}"
  end

  let!(:admin)     { enrolled_user(email: "admin@example.org", role: "municipal_admin") }
  let!(:author)    { enrolled_user(email: "author@example.org", role: "protocol_author") }
  let!(:publisher) { enrolled_user(email: "pub@example.org", role: "protocol_publisher") }
  let!(:ana)       { enrolled_user(email: "ana@example.org", role: "protocol_reviewer") }
  let!(:bia)       { enrolled_user(email: "bia@example.org", role: "protocol_reviewer") }

  let(:non_scalars) { { "array" => %w[dengue zika], "hash" => { "a" => "dengue" } } }

  # v1 active com linha-base e v2 ativada por assinatura: `name` reverte.
  def revertible!(name)
    legacy = ProtocolDefinition.create!(name: name, version: 1, status: "active", activated_at: 3.days.ago,
                                        definition: protocol_definition_hash(name: name))
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil, created_at: 3.days.ago)
    v2 = ProtocolDefinition.create!(name: name, version: 2, status: "published",
                                    definition: protocol_definition_hash(name: name, version: 2))
    sign!(v2, purpose: "activation", by: ana)
    sign!(v2, purpose: "activation", by: bia)
    expect(Protocols::Activate.call(version: 2, name: name, by: publisher)).to be_ok
  end

  it "POST /protocols/revert with name as an array of two revertible protocols: 400, nothing reverted" do
    revertible!("dengue")
    revertible!("zika")
    sign_in_stepped_up!(publisher)

    expect {
      post "/protocols/revert", params: { name: %w[dengue zika], reason: "erro" }, as: :json
    }.not_to change(ProtocolActivation, :count)

    expect_bad_request("revert name array")
    expect(ProtocolDefinition.where(version: 2, status: "active").count).to eq(2)
  end

  it "every lifecycle endpoint refuses a non-scalar name" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash)

    non_scalars.each do |shape, value|
      sign_in_as(author)
      post "/protocols/1/submit", params: { name: value }, as: :json
      expect_bad_request("submit name #{shape}")

      sign_in_stepped_up!(ana)
      post "/protocols/1/signatures", params: { name: value, purpose: "publication" }, as: :json
      expect_bad_request("sign name #{shape}")

      sign_in_stepped_up!(publisher)
      post "/protocols/1/publish", params: { name: value }, as: :json
      expect_bad_request("publish name #{shape}")

      sign_in_stepped_up!(publisher)
      post "/protocols/1/activate", params: { name: value }, as: :json
      expect_bad_request("activate name #{shape}")

      sign_in_stepped_up!(publisher)
      post "/protocols/1/retire", params: { name: value }, as: :json
      expect_bad_request("retire name #{shape}")

      sign_in_stepped_up!(publisher)
      post "/protocols/revert", params: { name: value, reason: "erro" }, as: :json
      expect_bad_request("revert name #{shape}")
    end

    expect(ProtocolDefinition.find_by(name: "dengue", version: 1).status).to eq("draft")
  end

  it "signing refuses a non-scalar purpose, and revert a non-scalar reason" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review", definition: protocol_definition_hash)
    revertible!("zika")

    non_scalars.each do |shape, _|
      value = shape == "array" ? %w[publication activation] : { "p" => "publication" }
      sign_in_stepped_up!(ana)
      expect {
        post "/protocols/1/signatures", params: { name: "dengue", purpose: value }, as: :json
      }.not_to change(ProtocolSignature, :count)
      expect_bad_request("sign purpose #{shape}")

      reason = shape == "array" ? %w[um dois] : { "r" => "erro" }
      sign_in_stepped_up!(publisher)
      expect {
        post "/protocols/revert", params: { name: "zika", reason: reason }, as: :json
      }.not_to change(ProtocolActivation, :count)
      expect_bad_request("revert reason #{shape}")
    end
  end

  it "POST /setup/memberships refuses a non-scalar user_id or role, and grants nothing" do
    sign_in_as(admin)

    [
      [ "user_id array", { user_id: [ author.id, publisher.id ], role: "protocol_reviewer" } ],
      [ "user_id hash",  { user_id: { "id" => author.id }, role: "protocol_reviewer" } ],
      [ "role array",    { user_id: author.id, role: %w[protocol_reviewer municipal_admin] } ],
      [ "role hash",     { user_id: author.id, role: { "r" => "protocol_reviewer" } } ]
    ].each do |label, body|
      expect {
        post "/setup/memberships", params: body, as: :json
      }.not_to change(Membership, :count)
      expect_bad_request(label)
    end
  end

  it "POST /setup/invitations refuses a non-scalar email or role" do
    sign_in_as(admin)

    [
      [ "email array", { email: %w[a@example.org b@example.org], role: "viewer" } ],
      [ "role hash",   { email: "a@example.org", role: { "r" => "viewer" } } ]
    ].each do |label, body|
      expect {
        post "/setup/invitations", params: body, as: :json
      }.not_to change(Invitation, :count)
      expect_bad_request(label)
    end
  end

  it "a missing required parameter is the same 400 bad_request" do
    sign_in_as(author)
    post "/protocols/1/submit", params: {}, as: :json

    expect_bad_request("submit without name")
  end

  it "scalar values keep working (revert with a scalar reason)" do
    revertible!("dengue")
    sign_in_stepped_up!(publisher)

    post "/protocols/revert", params: { name: "dengue", reason: "v2 erra a prioridade" }, as: :json

    expect(response).to have_http_status(:ok)
  end
end
