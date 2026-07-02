require "rails_helper"

RSpec.describe "Setup accept_invitation", type: :request do
  let(:muni) { create(:municipality) }
  let!(:operator) do
    u = User.create!(email_address: "op-#{SecureRandom.hex(3)}@example.org", password: "secret123")
    Membership.create!(user: u, role: "platform_operator", granted_at: Time.current)
    u
  end
  let!(:inv) do
    ApplicationRecord.connected_to(role: :admin) do
      Invitation.create!(
        email: "new-#{SecureRandom.hex(3)}@example.org", role: "municipal_admin", municipality: muni,
        token: "tok-#{SecureRandom.hex(4)}", invited_by: operator, expires_at: 1.day.from_now
      )
    end
  end

  it "accepts a valid invitation (the rate_limit macro does not break the public endpoint)" do
    post "/setup/accept_invitation", params: { token: inv.token, password: "secretpw-1" }
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)["email_address"]).to eq(inv.email)
  end

  it "rejects an invalid token with 422 (endpoint reachable, not rate-limited away)" do
    post "/setup/accept_invitation", params: { token: "nope", password: "x" }
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
