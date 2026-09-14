require "rails_helper"

# Grant assinado de entrada numa cidade (spec §5, Plano 3B): 60 s, uso único,
# válido só na cidade para a qual foi emitido. A linha em city_grants é a fonte
# da verdade; o token só aponta para ela.
RSpec.describe CityGrants do
  include ActiveSupport::Testing::TimeHelpers

  let(:city) { create(:city) }
  let(:other_city) { create(:city) }
  let(:subject_id) { SecureRandom.uuid }

  def issue(kind: "operator", for_city: city)
    described_class.issue(city: for_city, kind: kind, subject_id: subject_id)
  end

  it "issues a token backed by an unconsumed grant row that expires in 60 seconds" do
    token = nil
    expect { token = issue }.to change(CityGrant, :count).by(1)

    grant = CityGrant.order(:created_at).last
    expect(token).to be_a(String)
    expect(grant).to have_attributes(city_id: city.id, kind: "operator", subject_id: subject_id, consumed_at: nil)
    expect(grant.expires_at).to be_within(2.seconds).of(60.seconds.from_now)
  end

  it "the token carries only the grant id and the city slug" do
    payload = Rails.application.message_verifier(:city_grant).verified(issue, purpose: :city_grant)

    expect(payload.keys).to contain_exactly("jti", "city")
    expect(payload["city"]).to eq(city.slug)
  end

  it "redeems once, in the city it was issued for, returning the grant from the database" do
    token = issue(kind: "user")

    grant = described_class.redeem(token: token, city: city)

    expect(grant).to have_attributes(kind: "user", subject_id: subject_id, city_id: city.id)
    expect(grant.consumed_at).to be_present
    expect(described_class.redeem(token: token, city: city)).to be_nil
  end

  it "refuses another city without consuming the grant" do
    token = issue

    expect(described_class.redeem(token: token, city: other_city)).to be_nil
    expect(CityGrant.order(:created_at).last.consumed_at).to be_nil
    expect(described_class.redeem(token: token, city: city)).to be_present
  end

  it "refuses an expired grant" do
    token = issue

    travel 61.seconds do
      expect(described_class.redeem(token: token, city: city)).to be_nil
    end
  end

  it "refuses a grant whose row expired even if the token signature is still valid" do
    token = issue
    CityGrant.order(:created_at).last.update!(expires_at: 1.second.ago)

    expect(described_class.redeem(token: token, city: city)).to be_nil
  end

  it "refuses a tampered token, a token with another purpose and a non-string token" do
    token = issue
    foreign = Rails.application.message_verifier(:city_grant).generate(
      { "jti" => CityGrant.order(:created_at).last.id, "city" => city.slug }, purpose: :other
    )

    expect(described_class.redeem(token: "#{token}x", city: city)).to be_nil
    expect(described_class.redeem(token: foreign, city: city)).to be_nil
    expect(described_class.redeem(token: [ token ], city: city)).to be_nil
    expect(described_class.redeem(token: "", city: city)).to be_nil
    expect(described_class.redeem(token: token, city: city)).to be_present
  end

  it "refuses a grant consumed by a concurrent request" do
    token = issue
    CityGrant.order(:created_at).last.update!(consumed_at: Time.current)

    expect(described_class.redeem(token: token, city: city)).to be_nil
  end

  it "rejects an unknown kind" do
    expect { issue(kind: "admin") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "the platform database refuses an unknown kind even skipping validation" do
    grant = CityGrant.new(city: city, kind: "admin", subject_id: subject_id, expires_at: 1.minute.from_now)

    expect { grant.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /ck_city_grants_kind/)
  end
end
