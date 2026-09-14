require "rails_helper"

RSpec.describe RevokeMembership do
  let!(:by) { User.create!(email_address: "by@x.com", password: "secret123") }
  let!(:user) { User.create!(email_address: "u@x.com", password: "secret123") }
  let!(:m) { Membership.create!(user: user, role: "viewer", granted_at: Time.current) }

  # membership.revoked is a CITY event (Ruling R18): DomainEvents.publish needs
  # Current.city set — the harness only opens the connection.
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "end-date e publica membership.revoked" do
    described_class.call(membership_id: m.id, by: by)
    expect(m.reload.revoked_at).to be_present

    event = DomainEvent.find_by!(name: "membership.revoked")
    expect(event.payload).to include("user_id" => user.id, "role" => "viewer", "by" => by.id)
  end
end
