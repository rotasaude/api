# apps/api/spec/models/membership_spec.rb
require "rails_helper"

RSpec.describe Membership do
  let!(:user) { User.create!(email_address: "m@example.org", password: "secret123") }
  let!(:muni) { create(:municipality) }

  it "operator membership tem municipality_id nulo" do
    m = Membership.create!(user: user, role: "platform_operator", granted_at: Time.current)
    expect(m.operator?).to be true
    expect(user.reload.operator?).to be true
  end

  it "operator com municipality_id setado é inválido" do
    m = Membership.new(user: user, municipality: muni, role: "platform_operator", granted_at: Time.current)
    expect(m).to be_invalid
  end

  it "índice único parcial bloqueia membership duplicado ativo" do
    Membership.create!(user: user, municipality: muni, role: "municipal_admin", granted_at: Time.current)
    expect {
      Membership.create!(user: user, municipality: muni, role: "municipal_admin", granted_at: Time.current)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "revogar permite reconceder linha nova" do
    m = Membership.create!(user: user, municipality: muni, role: "viewer", granted_at: Time.current)
    m.revoke!
    expect {
      Membership.create!(user: user, municipality: muni, role: "viewer", granted_at: Time.current)
    }.not_to raise_error
  end
end
