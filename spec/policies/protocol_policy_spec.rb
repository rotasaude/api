require "rails_helper"

RSpec.describe ProtocolPolicy do
  let(:muni) { create(:municipality) }
  let(:protocol) { double(:protocol, municipality_id: muni.id) }

  it "publisher pode publicar" do
    user = User.create!(email_address: "p@example.org", password: "secret123")
    Membership.create!(user: user, municipality: muni, role: "protocol_publisher", granted_at: Time.current)
    expect(described_class.new(user, protocol).publish?).to be true
  end

  it "operador pode publicar cross-tenant" do
    user = User.create!(email_address: "op@example.org", password: "secret123")
    Membership.create!(user: user, role: "platform_operator", granted_at: Time.current)
    expect(described_class.new(user, protocol).publish?).to be true
  end

  it "viewer não pode publicar" do
    user = User.create!(email_address: "v@example.org", password: "secret123")
    Membership.create!(user: user, municipality: muni, role: "viewer", granted_at: Time.current)
    expect(described_class.new(user, protocol).publish?).to be false
  end
end
