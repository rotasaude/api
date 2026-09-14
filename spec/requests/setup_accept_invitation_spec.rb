require "rails_helper"

# City is the request's host city (TEST_CITY_A, the harness default — see
# spec/support/city_request_auth.rb). `invited_by` must be a User OF THIS
# CITY: invitations.invited_by_id is an FK to the city's own users table (no
# more platform_operator inviting cross-tenant — Membership has no such role;
# ck_memberships_role only accepts the 4 local roles).
RSpec.describe "Setup accept_invitation", type: :request do
  let!(:inviter) { User.create!(email_address: "admin-#{SecureRandom.hex(3)}@example.org", password: "secret123") }
  let!(:inv) do
    Invitation.create!(
      email: "new-#{SecureRandom.hex(3)}@example.org", role: "municipal_admin",
      token: "tok-#{SecureRandom.hex(4)}", invited_by: inviter, expires_at: 1.day.from_now
    )
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
