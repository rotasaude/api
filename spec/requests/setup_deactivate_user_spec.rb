require "rails_helper"

# F-06.10: desativar usuário da cidade. Só municipal_admin, sempre com step-up
# de MFA recente (desativar derruba o acesso de alguém — mesmo risco de revogar
# papel privilegiado). Nunca a si mesmo.
RSpec.describe "POST /setup/users/:id/deactivate", type: :request do
  def json = JSON.parse(response.body)

  def enrolled_user(email:, role: nil)
    u = User.create!(email_address: email, password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    Membership.create!(user: u, role: role, granted_at: Time.current) if role
    u
  end

  let!(:admin)  { enrolled_user(email: "adm-#{SecureRandom.hex(3)}@example.org", role: "municipal_admin") }
  let!(:target) { enrolled_user(email: "alvo-#{SecureRandom.hex(3)}@example.org", role: "viewer") }

  def sign_in_admin!(stepped_up: true)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
    session
  end

  def deactivate!(id = target.id)
    post "/setup/users/#{id}/deactivate", as: :json
  end

  it "quem não é municipal_admin leva 403 e nada muda" do
    other = enrolled_user(email: "zz-#{SecureRandom.hex(3)}@example.org", role: "viewer")
    sign_in_as(other).update!(mfa_verified_at: Time.current)

    deactivate!

    expect(response).to have_http_status(:forbidden)
    expect(target.reload.deactivated_at).to be_nil
  end

  it "sem janela de step-up: 401 mfa_required e nada muda" do
    target_session = target.sessions.create!(user_agent: "x", ip_address: "127.0.0.1")
    sign_in_admin!(stepped_up: false)

    deactivate!

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "mfa_required")
    expect(target.reload.deactivated_at).to be_nil
    expect(Session.exists?(target_session.id)).to be(true)
    expect(DomainEvent.where(name: "user.deactivated")).to be_empty
  end

  it "com step-up: desativa, derruba as sessões do alvo e publica user.deactivated" do
    target_session = target.sessions.create!(user_agent: "x", ip_address: "127.0.0.1")
    sign_in_admin!

    deactivate!

    expect(response).to have_http_status(:ok)
    expect(target.reload.deactivated_at).to be_present
    expect(json).to eq("id" => target.id, "deactivated_at" => target.deactivated_at.iso8601)
    expect(Session.exists?(target_session.id)).to be(false)
    event = DomainEvent.find_by!(name: "user.deactivated")
    expect(event.payload).to include("user_id" => target.id, "by" => admin.id)
    expect(target.memberships.active).to be_empty
    expect(DomainEvent.find_by!(name: "membership.revoked").payload)
      .to include("user_id" => target.id, "role" => "viewer", "by" => admin.id)
  end

  it "a sessão que o alvo já tinha deixa de autenticar" do
    sign_in_as(target)
    target_cookie = cookies[:session_id]
    sign_in_admin!
    deactivate!
    expect(response).to have_http_status(:ok)

    cookies[:session_id] = target_cookie
    get "/session", as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "recusa desativar a si mesmo (422 cannot_deactivate_self)" do
    sign_in_admin!

    deactivate!(admin.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("cannot_deactivate_self")
    expect(admin.reload.deactivated_at).to be_nil
  end

  it "usuário desconhecido: 404" do
    sign_in_admin!

    deactivate!(SecureRandom.uuid)

    expect(response).to have_http_status(:not_found)
  end

  it "já desativado: 422 already_deactivated" do
    target.update!(deactivated_at: 1.day.ago)
    sign_in_admin!

    deactivate!

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("already_deactivated")
  end
end
