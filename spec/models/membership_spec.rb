# apps/api/spec/models/membership_spec.rb
require "rails_helper"

RSpec.describe Membership do
  let!(:user) { User.create!(email_address: "m@example.org", password: "secret123") }

  # Fix round 1 (I1): the old "operator" examples were skipped because
  # Membership no longer carries a platform-operator concept — but that gap
  # is exactly today's fail-closed behaviour, and it's provable without
  # constructing anything: platform_operator fails Ruby-level validation,
  # fails the DB CHECK constraint if validation is bypassed, and even a real
  # active membership can never make User#operator? true (D3). The invariant
  # ("no city user can become a platform operator") now lives across these
  # three layers instead of a single Membership attribute.
  it "platform_operator é inválido no nível de Ruby (Membership::ROLES)" do
    m = Membership.new(user: user, role: "platform_operator", granted_at: Time.current)
    expect(m).to be_invalid
    expect(m.errors[:role]).to be_present
  end

  it "platform_operator viola ck_memberships_role no banco da cidade, mesmo pulando a validação" do
    m = Membership.new(user: user, role: "platform_operator", granted_at: Time.current)
    expect {
      m.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid, /ck_memberships_role/)
  end

  it "user.operator? é false mesmo com uma membership municipal_admin ativa" do
    Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    expect(user.reload.operator?).to be(false)
  end

  it "índice único parcial bloqueia membership duplicado ativo" do
    Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    expect {
      Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "revogar permite reconceder linha nova" do
    m = Membership.create!(user: user, role: "viewer", granted_at: Time.current)
    m.revoke!
    expect {
      Membership.create!(user: user, role: "viewer", granted_at: Time.current)
    }.not_to raise_error
  end
end
