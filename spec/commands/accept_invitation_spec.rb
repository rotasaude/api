require "rails_helper"

RSpec.describe AcceptInvitation do
  let(:muni) { create(:municipality) }
  let!(:operator) do
    u = User.create!(email_address: "op@example.org", password: "secret123")
    Membership.create!(user: u, role: "platform_operator", granted_at: Time.current)
    u
  end
  let!(:inv) do
    ApplicationRecord.connected_to(role: :admin) do
      Invitation.create!(
        email: "new@example.org", role: "municipal_admin", municipality: muni,
        token: "abc123", invited_by: operator, expires_at: 1.day.from_now
      )
    end
  end

  it "cria user + membership a partir do convite" do
    res = described_class.call(token: "abc123", password: "secretpw")
    expect(res.ok?).to be true
    user = res.payload[:user]
    ApplicationRecord.connected_to(role: :admin) do
      expect(Membership.where(user: user, municipality: muni, role: "municipal_admin").exists?).to be true
      expect(inv.reload.accepted_at).to be_present
    end
  end

  it "rejeita token inválido" do
    res = described_class.call(token: "nope", password: "x")
    expect(res.failure?).to be true
  end
end
