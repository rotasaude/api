require "rails_helper"

RSpec.describe Whatsapp::SessionWindow do
  let(:muni) { create(:municipality) }
  let(:phone) { "5511999990000" }

  around do |ex|
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      ex.run
      raise ActiveRecord::Rollback
    end
  end

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
