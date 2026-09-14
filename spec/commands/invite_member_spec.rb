require "rails_helper"

RSpec.describe InviteMember do
  # invited_by is a User of the current city's connection (no more
  # municipality_id: nil / platform_operator — Membership has no such role).
  let(:inviter) { User.create!(email_address: "admin@example.org", password: "secret123") }

  # user.invited is a CITY event (Ruling R18): DomainEvents.publish needs
  # Current.city set — the harness only opens the connection.
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "cria convite e publica user.invited no domain_events da cidade" do
    res = described_class.call(email: "new@example.org", role: "municipal_admin", invited_by: inviter)
    expect(res.ok?).to be true
    inv = res.payload[:invitation]
    expect(Invitation.find(inv.id).role).to eq("municipal_admin")

    event = DomainEvent.find_by!(name: "user.invited")
    expect(event.payload).to include("email" => "new@example.org", "role" => "municipal_admin", "invitation_id" => inv.id)
  end
end
