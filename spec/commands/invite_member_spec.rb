require "rails_helper"

RSpec.describe InviteMember do
  let(:muni) { create(:municipality) }
  let(:operator) do
    u = User.create!(email_address: "op@example.org", password: "secret123")
    Membership.create!(user: u, role: "platform_operator", granted_at: Time.current)
    u
  end

  it "cria convite e emite Platform.audit quando municipality_id é NULL" do
    expect(Platform).to receive(:audit).with("user.invited", anything)
    res = described_class.call(email: "new@example.org", role: "platform_operator", municipality_id: nil, invited_by: operator)
    expect(res.ok?).to be true
  end
end
