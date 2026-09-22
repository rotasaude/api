require "rails_helper"

# Spec do dashboard §4.1: conceder e revogar papel PRIVILEGIADO
# (Membership::PRIVILEGED_ROLES) exige step-up de MFA. Decidir quem revisa
# protocolo é decidir quem aprova protocolo clínico: uma sessão roubada, só
# com a senha, montaria dois revisores e publicaria qualquer coisa.
#
# Muda o §8 de 2026-09-18-protocol-signatures-design.md, que dizia
# "não em conceder papel".
RSpec.describe "Setup privileged role step-up", type: :request do
  def json = JSON.parse(response.body)

  def enrolled_user(email:, role: nil)
    u = User.create!(email_address: email, password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    Membership.create!(user: u, role: role, granted_at: Time.current) if role
    u
  end

  let!(:admin)  { enrolled_user(email: "adm-#{SecureRandom.hex(3)}@example.org", role: "municipal_admin") }
  let!(:target) { enrolled_user(email: "alvo-#{SecureRandom.hex(3)}@example.org", role: "protocol_publisher") }

  def sign_in_admin!(stepped_up:)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
    session
  end

  def grant!(role: "protocol_reviewer")
    post "/setup/memberships", params: { user_id: target.id, role: role }, as: :json
  end

  describe "conceder" do
    it "sem janela de step-up: 401 mfa_required e nenhuma membership criada" do
      sign_in_admin!(stepped_up: false)

      expect { grant! }.not_to change { Membership.where(user: target, role: "protocol_reviewer").count }
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
    end

    it "com a janela aberta: concede" do
      sign_in_admin!(stepped_up: true)

      grant!

      expect(response).to have_http_status(:created)
      expect(target.reload.has_role?("protocol_reviewer")).to be(true)
    end

    it "com a janela vencida (6 min): recusa" do
      sign_in_as(admin).update!(mfa_verified_at: 6.minutes.ago)

      grant!

      expect(response).to have_http_status(:unauthorized)
    end

    it "papel NÃO privilegiado continua sem step-up" do
      sign_in_admin!(stepped_up: false)

      grant!(role: "viewer")

      expect(response).to have_http_status(:created)
      expect(target.reload.has_role?("viewer")).to be(true)
    end

    it "quem não é municipal_admin leva 403 antes de qualquer checagem de MFA" do
      other = enrolled_user(email: "zz-#{SecureRandom.hex(3)}@example.org", role: "protocol_publisher")
      sign_in_as(other)

      grant!

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "revogar" do
    let!(:membership) { Membership.create!(user: target, role: "protocol_reviewer", granted_at: Time.current) }

    it "sem janela de step-up: 401 e a membership continua ativa" do
      sign_in_admin!(stepped_up: false)

      post "/setup/memberships/#{membership.id}/revoke", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(membership.reload.revoked_at).to be_nil
    end

    it "com a janela aberta: revoga" do
      sign_in_admin!(stepped_up: true)

      post "/setup/memberships/#{membership.id}/revoke", as: :json

      expect(response).to have_http_status(:ok)
      expect(membership.reload.revoked_at).to be_present
    end

    it "papel não privilegiado é revogado sem step-up" do
      plain = Membership.create!(user: target, role: "viewer", granted_at: Time.current)
      sign_in_admin!(stepped_up: false)

      post "/setup/memberships/#{plain.id}/revoke", as: :json

      expect(response).to have_http_status(:ok)
      expect(plain.reload.revoked_at).to be_present
    end
  end
end
