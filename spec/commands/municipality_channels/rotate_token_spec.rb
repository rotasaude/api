require "rails_helper"
require "ostruct"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe MunicipalityChannels::RotateToken, type: :model do
  self.use_transactional_tests = false
  before { clean_admin_tables }
  after  { clean_admin_tables }

  # Builds a municipality + active channel + a user with the given membership.
  # role/for_muni control the membership; returns a struct of ids/objects.
  def scenario(role:, for_muni: :same)
    as_admin do
      muni  = Municipality.create!(name: "Tok City", slug: "tok-city-#{SecureRandom.hex(3)}", ibge_code: "3500#{rand(100..999)}")
      other = Municipality.create!(name: "Other City", slug: "other-#{SecureRandom.hex(3)}", ibge_code: "3501#{rand(100..999)}")
      channel = MunicipalityChannel.create!(municipality: muni, phone_number_id: "PN#{SecureRandom.hex(3)}",
                                            waba_id: "WABA", display_phone_number: "+5511", access_token: "OLD", active: true)
      user = User.create!(email_address: "actor-#{SecureRandom.hex(3)}@x.com", password: "dev-password-123")
      unless role.nil?
        muni_id = role == "platform_operator" ? nil : (for_muni == :same ? muni.id : other.id)
        Membership.create!(user: user, role: role, municipality_id: muni_id, granted_at: Time.current)
      end
      OpenStruct.new(muni: muni, channel: channel, user: user)
    end
  end

  def token_of(channel_id)
    as_admin { MunicipalityChannel.find(channel_id).access_token }
  end

  it "rotates for a platform_operator and audits without the token value" do
    s = scenario(role: "platform_operator")
    result = described_class.call(municipality_id: s.muni.id, new_token: "NEW-TOKEN", by: s.user)
    expect(result.ok?).to be(true)
    expect(token_of(s.channel.id)).to eq("NEW-TOKEN")
    event = as_admin { DomainEvent.where(name: "channel.token_rotated").order(:occurred_at).last }
    expect(event).to be_present
    expect(event.payload.to_json).not_to include("NEW-TOKEN")
    expect(event.payload["phone_number_id"]).to eq(s.channel.phone_number_id)
  end

  it "rotates for a municipal_admin of the channel's city" do
    s = scenario(role: "municipal_admin", for_muni: :same)
    expect(described_class.call(municipality_id: s.muni.id, new_token: "NEW", by: s.user).ok?).to be(true)
    expect(token_of(s.channel.id)).to eq("NEW")
  end

  it "forbids a municipal_admin of another city and leaves the token unchanged" do
    s = scenario(role: "municipal_admin", for_muni: :other)
    result = described_class.call(municipality_id: s.muni.id, new_token: "NEW", by: s.user)
    expect(result.failure?).to be(true)
    expect(result.reason).to eq(:forbidden)
    expect(token_of(s.channel.id)).to eq("OLD")
  end

  it "forbids a user with no qualifying membership" do
    s = scenario(role: nil)
    expect(described_class.call(municipality_id: s.muni.id, new_token: "NEW", by: s.user).reason).to eq(:forbidden)
  end

  it "returns not_found when the municipality has no active channel" do
    s = scenario(role: "platform_operator")
    as_admin { s.channel.update!(active: false) }
    expect(described_class.call(municipality_id: s.muni.id, new_token: "NEW", by: s.user).reason).to eq(:not_found)
  end

  it "returns invalid for a blank token and leaves the token unchanged" do
    s = scenario(role: "platform_operator")
    expect(described_class.call(municipality_id: s.muni.id, new_token: "", by: s.user).reason).to eq(:invalid)
    expect(token_of(s.channel.id)).to eq("OLD")
  end
end
