require "rails_helper"
require "ostruct"

RSpec.describe MunicipalityChannels::RotateToken, type: :model do
  # `city` is the channel's own city (TEST_CITY_A, the harness's default
  # connection); `other_city` is a second, distinct city (TEST_CITY_B) used to
  # prove custody is per-city. Roles now live in the CITY's own memberships
  # table (D12: only municipal_admin of the channel's city — the platform
  # operator grant is Plan 3, there is no cross-tenant role any more).
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active",
                  database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key)
  end
  let!(:other_city) do
    create(:city, slug: TEST_CITY_B.slug, status: "active",
                  database_url: city_database_url("rota_saude_test_city_b"))
  end
  let!(:channel) do
    CityChannel.create!(city: city, phone_number_id: "PN#{SecureRandom.hex(3)}",
                         waba_id: "WABA", display_phone_number: "+5511", access_token: "OLD", active: true)
  end

  def token_of(channel_id)
    CityChannel.find(channel_id).access_token
  end

  it "rotates for a municipal_admin of the channel's city and audits without the token value" do
    admin = User.create!(email_address: "admin-#{SecureRandom.hex(3)}@x.com", password: "dev-password-123")
    Membership.create!(user: admin, role: "municipal_admin", granted_at: Time.current)

    result = described_class.call(city: city, new_token: "NEW-TOKEN", by: admin)

    expect(result.ok?).to be(true)
    expect(token_of(channel.id)).to eq("NEW-TOKEN")

    event = PlatformEvent.where(name: "channel.token_rotated").order(:occurred_at).last
    expect(event).to be_present
    expect(event.payload.to_json).not_to include("NEW-TOKEN")
    expect(event.payload).to include("city_id" => city.id, "phone_number_id" => channel.phone_number_id, "by" => admin.id)
  end

  it "the platform operator grant (cross-city custody) is Plan 3" do
    skip "Plano 3: grant de operador — não há mais papel de plataforma em Membership " \
         "(ck_memberships_role só aceita os 4 papéis locais); custódia cross-tenant " \
         "volta com Operator + grant de entrada na cidade"
  end

  it "forbids a municipal_admin of another city and leaves the token unchanged" do
    outsider = CityConnection.with(other_city) do
      u = User.create!(email_address: "admin-#{SecureRandom.hex(3)}@other.com", password: "dev-password-123")
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
      u
    end

    result = described_class.call(city: city, new_token: "NEW", by: outsider)
    expect(result.failure?).to be(true)
    expect(result.reason).to eq(:forbidden)
    expect(token_of(channel.id)).to eq("OLD")
  end

  it "forbids a user with no qualifying membership" do
    plain = User.create!(email_address: "plain-#{SecureRandom.hex(3)}@x.com", password: "dev-password-123")
    expect(described_class.call(city: city, new_token: "NEW", by: plain).reason).to eq(:forbidden)
  end

  it "returns not_found when the city has no active channel" do
    admin = User.create!(email_address: "admin2-#{SecureRandom.hex(3)}@x.com", password: "dev-password-123")
    Membership.create!(user: admin, role: "municipal_admin", granted_at: Time.current)
    channel.update!(active: false)

    expect(described_class.call(city: city, new_token: "NEW", by: admin).reason).to eq(:not_found)
  end

  it "returns invalid for a blank token and leaves the token unchanged" do
    admin = User.create!(email_address: "admin3-#{SecureRandom.hex(3)}@x.com", password: "dev-password-123")
    Membership.create!(user: admin, role: "municipal_admin", granted_at: Time.current)

    expect(described_class.call(city: city, new_token: "", by: admin).reason).to eq(:invalid)
    expect(token_of(channel.id)).to eq("OLD")
  end
end
