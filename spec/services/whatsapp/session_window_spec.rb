require "rails_helper"

RSpec.describe Whatsapp::SessionWindow do
  let(:phone) { "5511999990000" }

  # The example already runs inside TEST_CITY_A's connection and its fixture
  # transaction (5c-1); SessionWindow.open?(phone:) reads InboundMessage on
  # whichever connection is current, so no Current.city is needed here (it
  # never reads it).
  def inbound(at:)
    InboundMessage.create!(
      message_id: "wamid.#{SecureRandom.hex(6)}", from: phone, kind: "text",
      raw: { "type" => "text" }.to_json, created_at: at
    )
  end

  it "is open when the last inbound is within 24h" do
    inbound(at: 2.hours.ago)
    expect(described_class.open?(phone: phone)).to be(true)
  end

  it "is closed when the last inbound is older than 24h" do
    inbound(at: 25.hours.ago)
    expect(described_class.open?(phone: phone)).to be(false)
  end

  it "is closed when there is no inbound" do
    expect(described_class.open?(phone: phone)).to be(false)
  end
end
