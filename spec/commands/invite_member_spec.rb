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

  # F-06.9: o convite não duplica quem já está na cidade nem um convite vivo.
  it "recusa e-mail de usuário que já existe na cidade (already_member), sem criar convite" do
    User.create!(email_address: "ja@example.org", password: "secret123")

    res = nil
    expect { res = described_class.call(email: "JA@example.org", role: "viewer", invited_by: inviter) }
      .not_to change(Invitation, :count)
    expect(res.reason).to eq(:already_member)
    expect(res.message).to be_present
  end

  it "recusa e-mail com convite pendente (already_invited)" do
    described_class.call(email: "pend@example.org", role: "viewer", invited_by: inviter)

    res = described_class.call(email: "Pend@example.org", role: "protocol_author", invited_by: inviter)

    expect(res.reason).to eq(:already_invited)
    expect(Invitation.where(email: "pend@example.org").count).to eq(1)
  end

  it "convida de novo quando o convite anterior venceu ou foi aceito" do
    old = described_class.call(email: "venc@example.org", role: "viewer", invited_by: inviter).payload[:invitation]
    old.update_column(:expires_at, 1.minute.ago)

    expect(described_class.call(email: "venc@example.org", role: "viewer", invited_by: inviter).ok?).to be(true)
  end
end
