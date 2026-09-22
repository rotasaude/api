require "rails_helper"

# Task 4 do plano "assinaturas — API da cidade": conceder papel pela API
# (spec de assinaturas §3, POST /setup/memberships). O command (GrantRole) já
# tem cobertura própria em spec/commands/grant_role_spec.rb; este spec cobre
# só a borda HTTP — gate de autorização, formato da resposta e status codes —
# e a integração fim a fim com a rota de revogação já existente.
RSpec.describe "Setup grant_role", type: :request do
  def json = JSON.parse(response.body)

  # protocol_reviewer é privilegiado (Membership::PRIVILEGED_ROLES) desde a
  # Task 1 da fatia "dashboard-signatures": conceder ou revogar exige step-up
  # de MFA, então o admin precisa estar inscrito para poder carimbar a janela
  # nos testes que concedem/revogam esse papel.
  let!(:admin) do
    User.create!(email_address: "admin-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let!(:publisher) do
    User.create!(email_address: "pub-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
  end

  it "lets a municipal_admin turn a publisher into a reviewer too" do
    sign_in_as(admin).update!(mfa_verified_at: Time.current)

    post "/setup/memberships", params: { user_id: publisher.id, role: "protocol_reviewer" }, as: :json

    expect(response).to have_http_status(:created)
    expect(json["user_id"]).to eq(publisher.id)
    expect(json["role"]).to eq("protocol_reviewer")
    expect(json["id"]).to be_present
    expect(json["granted_at"]).to be_present
    expect(publisher.reload.has_role?(:protocol_reviewer)).to be(true)

    event = DomainEvent.where(name: "membership.granted").order(:occurred_at).last
    expect(event.payload).to include("user_id" => publisher.id, "role" => "protocol_reviewer")
  end

  it "refuses a publisher who is not admin: 403, nothing created" do
    sign_in_as(publisher)

    post "/setup/memberships", params: { user_id: publisher.id, role: "protocol_reviewer" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(publisher.reload.has_role?(:protocol_reviewer)).to be(false)
  end

  it "responds 422 invalid_role for an unknown role" do
    sign_in_as(admin)

    post "/setup/memberships", params: { user_id: publisher.id, role: "god" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid_role")
    expect(json["message"]).to be_present
  end

  it "responds 422 already_granted when the role is already held" do
    sign_in_as(admin)

    post "/setup/memberships", params: { user_id: publisher.id, role: "protocol_publisher" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("already_granted")
    expect(json["message"]).to be_present
  end

  it "responds 422 user_not_found for a user that does not exist" do
    sign_in_as(admin)

    post "/setup/memberships", params: { user_id: SecureRandom.uuid, role: "viewer" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("user_not_found")
  end

  it "revokes the granted role through the existing route, and the reviewer stops counting" do
    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    post "/setup/memberships", params: { user_id: publisher.id, role: "protocol_reviewer" }, as: :json
    membership_id = json["id"]

    pd = ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review",
                                    definition: protocol_definition_hash)
    expect(Protocols::Signatures.eligible_reviewer_count(pd)).to eq(1)

    post "/setup/memberships/#{membership_id}/revoke", as: :json
    expect(response).to have_http_status(:ok)

    expect(Protocols::Signatures.eligible_reviewer_count(pd)).to eq(0)
  end

  it "refuses an operator grant session with 403 operator_read_only" do
    operator = Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                                otp_secret: ROTP::Base32.random, otp_enabled: true)
    sign_in_operator_grant(operator)

    post "/setup/memberships", params: { user_id: publisher.id, role: "protocol_reviewer" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "operator_read_only")
  end
end
