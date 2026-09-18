require "rails_helper"

# Spec de assinaturas §3 e §7: só o municipal_admin concede papel, e o
# mantenedor nunca concede quem aprova protocolo nem quem concede aprovação.
RSpec.describe GrantRole do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:admin) do
    User.create!(email_address: "ad-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
    end
  end
  let(:publisher) do
    User.create!(email_address: "pb-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
  end
  let(:maintainer_actor) do
    Maintenance::MaintainerActor.new(
      Maintainer.create!(email_address: "gm-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                         otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    )
  end

  it "lets a municipal admin make a publisher a reviewer too, and records who granted it" do
    result = described_class.call(user_id: publisher.id, role: "protocol_reviewer", by: admin)

    expect(result.ok?).to be(true)
    expect(publisher.reload.has_role?(:protocol_reviewer)).to be(true)
    expect(publisher.has_role?(:protocol_publisher)).to be(true)
    expect(result.payload[:membership].granted_by_id).to eq(admin.id)
    event = DomainEvent.where(name: "membership.granted").order(:occurred_at).last
    expect(event.payload).to include("user_id" => publisher.id, "role" => "protocol_reviewer",
                                     "by" => admin.id, "actor_kind" => "user")
  end

  it "refuses anyone who is not a municipal admin" do
    other = publisher

    expect(described_class.call(user_id: other.id, role: "protocol_reviewer", by: other).reason).to eq(:forbidden)
  end

  it "refuses the maintainer for every privileged role, even though it passes every role question" do
    Membership::PRIVILEGED_ROLES.each do |role|
      result = described_class.call(user_id: publisher.id, role: role, by: maintainer_actor)

      expect(result.reason).to eq(:forbidden_for_maintainer)
    end
    expect(publisher.reload.has_role?(:protocol_reviewer)).to be(false)
  end

  it "lets the maintainer grant a role that is not privileged, without a granted_by user" do
    result = described_class.call(user_id: publisher.id, role: "viewer", by: maintainer_actor)

    expect(result.ok?).to be(true)
    expect(result.payload[:membership].granted_by_id).to be_nil
    expect(DomainEvent.where(name: "membership.granted").order(:occurred_at).last.payload)
      .to include("by" => maintainer_actor.id, "actor_kind" => "maintainer")
  end

  it "refuses an unknown role, a missing user, a deactivated user and a role already held" do
    expect(described_class.call(user_id: publisher.id, role: "god", by: admin).reason).to eq(:invalid_role)
    expect(described_class.call(user_id: SecureRandom.uuid, role: "viewer", by: admin).reason).to eq(:user_not_found)
    expect(described_class.call(user_id: publisher.id, role: "protocol_publisher", by: admin).reason)
      .to eq(:already_granted)

    publisher.update!(deactivated_at: Time.current)
    expect(described_class.call(user_id: publisher.id, role: "viewer", by: admin).reason).to eq(:user_inactive)
  end
end
