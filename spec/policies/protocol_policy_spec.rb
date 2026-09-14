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

  # Plan 3B will bring back a platform-operator grant, but ProtocolPolicy#publish?
  # is `role?(:protocol_publisher)` and never consults `operator?` — a user with
  # no membership at all must stay refused even if `operator?` were somehow
  # true. This pins that fail-closed behaviour so a future `|| operator?` added
  # to #publish? (the natural way someone would "restore" the operator grant)
  # gets caught immediately.
  it "operador (operator? true) sem membership não pode publicar — publish? nunca consulta operator?" do
    user = User.create!(email_address: "op@example.org", password: "secret123")
    allow(user).to receive(:operator?).and_return(true)
    expect(described_class.new(user, protocol).publish?).to be false
  end

  it "viewer não pode publicar" do
    user = User.create!(email_address: "v@example.org", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: Time.current)
    expect(described_class.new(user, protocol).publish?).to be false
  end
end
