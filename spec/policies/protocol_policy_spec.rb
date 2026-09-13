require "rails_helper"

RSpec.describe ProtocolPolicy do
  # ApplicationPolicy#role? only ever looks at the user's role in the current
  # city connection (the record is not consulted) — there is no
  # municipality_id to stand in for any more.
  let(:protocol) { double(:protocol) }

  it "publisher pode publicar" do
    user = User.create!(email_address: "p@example.org", password: "secret123")
    Membership.create!(user: user, role: "protocol_publisher", granted_at: Time.current)
    expect(described_class.new(user, protocol).publish?).to be true
  end

  it "operador pode publicar cross-tenant" do
    skip "Plano 3: grant de operador — platform_operator não é mais um role de Membership " \
         "(ck_memberships_role só aceita os 4 papéis locais da cidade); ProtocolPolicy só enxerga " \
         "o papel do usuário na cidade da conexão corrente, sem noção de cross-tenant"
  end

  it "viewer não pode publicar" do
    user = User.create!(email_address: "v@example.org", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: Time.current)
    expect(described_class.new(user, protocol).publish?).to be false
  end
end
