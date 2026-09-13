require "rails_helper"

RSpec.describe "InboundMessage#processed_at (F-02.8)", type: :model do
  it "round-trips a processed_at timestamp" do
    id = nil
    begin
      muni = Municipality.create!(name: "Proc City", slug: "proc-city", ibge_code: "3500020")
      msg = InboundMessage.create!(
        message_id: "wamid.proc1", from: "+551100", kind: "text",
        raw: { "type" => "text", "text" => { "body" => "oi" } }.to_json,
        municipality_id: muni.id
      )
      id = msg.id
      expect(msg.processed_at).to be_nil
      expect(msg.processed_at?).to be(false)
    end

    begin
      msg = InboundMessage.find(id)
      msg.update!(processed_at: Time.current)
      expect(InboundMessage.find(id).processed_at?).to be(true)
    end
  end
end
