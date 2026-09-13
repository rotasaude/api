require "rails_helper"

RSpec.describe AcceptInvitation do
  # invited_by is a User OF THIS CITY: invitations.invited_by_id is an FK to the
  # city's own users table (no more platform_operator inviting cross-tenant).
  let!(:inviter) { User.create!(email_address: "admin@example.org", password: "secret123") }
  let!(:inv) do
    Invitation.create!(
      email: "new@example.org", role: "municipal_admin",
      token: "abc123", invited_by: inviter, expires_at: 1.day.from_now
    )
  end

  # membership.granted is a CITY event (Ruling R18): DomainEvents.publish needs
  # Current.city set — the harness only opens the connection.
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "cria user + membership a partir do convite" do
    res = described_class.call(token: "abc123", password: "secretpw")
    expect(res.ok?).to be true
    user = res.payload[:user]
    expect(Membership.where(user: user, role: "municipal_admin").exists?).to be true
    expect(inv.reload.accepted_at).to be_present
  end

  it "rejeita token inválido" do
    res = described_class.call(token: "nope", password: "x")
    expect(res.failure?).to be true
  end
end
