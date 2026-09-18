require "rails_helper"

# Spec de assinaturas §7: sem esta recusa, o mantenedor convidaria duas contas
# de revisor e assinaria por elas — e a regra inteira cairia.
RSpec.describe "InviteMember and privileged roles" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:maintainer_actor) do
    Maintenance::MaintainerActor.new(
      Maintainer.create!(email_address: "im-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                         otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    )
  end

  it "refuses a maintainer inviting a reviewer or a municipal admin, and creates no invitation" do
    Membership::PRIVILEGED_ROLES.each do |role|
      result = InviteMember.call(email: "x-#{role}@example.org", role: role, invited_by: maintainer_actor)

      expect(result.reason).to eq(:forbidden_for_maintainer)
    end
    expect(Invitation.where(email: Membership::PRIVILEGED_ROLES.map { |r| "x-#{r}@example.org" })).to be_empty
  end

  it "still lets a municipal user invite a reviewer" do
    admin = User.create!(email_address: "ad-#{SecureRandom.hex(3)}@example.org", password: "secret123")
    Membership.create!(user: admin, role: "municipal_admin", granted_at: Time.current)

    expect(InviteMember.call(email: "novo@example.org", role: "protocol_reviewer", invited_by: admin).ok?).to be(true)
  end

  # M8: allowlist, not denylist — an actor whose actor_kind is neither "user"
  # nor "maintainer" must still be refused for a privileged role, because the
  # check requires actor_kind == "user" rather than enumerating "!= maintainer".
  it "refuses an actor whose kind is neither user nor maintainer for a privileged role" do
    other_kind_actor = Struct.new(:id, :actor_kind).new(SecureRandom.uuid, "service_token")

    result = InviteMember.call(email: "outro@example.org", role: "municipal_admin", invited_by: other_kind_actor)

    expect(result.reason).to eq(:forbidden_for_maintainer)
    expect(Invitation.where(email: "outro@example.org")).to be_empty
  end

  # M8: invited_by: nil is CityLifecycle::InviteAdmin's platform-operator path
  # (provisioning a city's first municipal_admin) — it must keep working
  # exactly as today, untouched by the actor-kind allowlist.
  it "still invites a municipal_admin when invited_by is nil (the platform operator's provisioning path)" do
    result = InviteMember.call(email: "primeiro-admin@example.org", role: "municipal_admin", invited_by: nil)

    expect(result.ok?).to be(true)
    expect(Invitation.find(result.payload[:invitation].id)).to have_attributes(
      email: "primeiro-admin@example.org", role: "municipal_admin"
    )
  end
end
