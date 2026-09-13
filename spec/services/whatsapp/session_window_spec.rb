require "rails_helper"

RSpec.describe Whatsapp::SessionWindow do
  let(:muni) { create(:municipality) }
  let(:phone) { "5511999990000" }

  # Was an `around` opening a transaction with SET LOCAL app.municipality_id (RLS).
  # Removed in 5c-1: raising before `ex.run` (e.g. `muni`) skipped rspec-rails'
  # fixture teardown and leaked the pinned transaction into the rest of the suite.
  # The example already runs inside TEST_CITY_A's connection and its fixture transaction.
  before { Current.city = TEST_CITY_A }

  after { Current.reset }

  def inbound(at:)
    InboundMessage.create!(
      message_id: "wamid.#{SecureRandom.hex(6)}", from: phone, kind: "text",
      raw: { "type" => "text" }.to_json, municipality_id: muni.id, created_at: at
    )
  end

  it "is open when the last inbound is within 24h" do
    inbound(at: 2.hours.ago)
    expect(described_class.open?(phone: phone, municipality_id: muni.id)).to be(true)
  end

  it "is closed when the last inbound is older than 24h" do
    inbound(at: 25.hours.ago)
    expect(described_class.open?(phone: phone, municipality_id: muni.id)).to be(false)
  end

  it "is closed when there is no inbound" do
    expect(described_class.open?(phone: phone, municipality_id: muni.id)).to be(false)
  end
end
