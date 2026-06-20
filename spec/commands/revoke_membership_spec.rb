require "rails_helper"

RSpec.describe RevokeMembership do
  let!(:by) { User.create!(email_address: "by@x.com", password: "secret123") }
  let!(:user) { User.create!(email_address: "u@x.com", password: "secret123") }
  let!(:muni) { create(:municipality) }
  let!(:m) { Membership.create!(user: user, municipality: muni, role: "viewer", granted_at: Time.current) }

  it "end-date e publica membership.revoked" do
    described_class.call(membership_id: m.id, by: by)
    expect(m.reload.revoked_at).to be_present
  end
end
