require "rails_helper"

RSpec.describe "InboundMessage#processed_at (F-02.8)", type: :model do
  it "round-trips a processed_at timestamp" do
    msg = InboundMessage.create!(
      message_id: "wamid.proc1", from: "+551100", kind: "text",
      raw: { "type" => "text", "text" => { "body" => "oi" } }.to_json
    )
    expect(msg.processed_at).to be_nil
    expect(msg.processed_at?).to be(false)

    msg.update!(processed_at: Time.current)
    expect(InboundMessage.find(msg.id).processed_at?).to be(true)
  end
end
