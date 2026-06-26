require "rails_helper"

RSpec.describe Whatsapp::Ingest do
  self.use_transactional_tests = false

  before do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM processed_events")
      ApplicationRecord.connection.execute("DELETE FROM inbound_messages")
      ApplicationRecord.connection.execute("DELETE FROM unknown_channels")
      ApplicationRecord.connection.execute("DELETE FROM municipality_channels")
      ApplicationRecord.connection.execute("DELETE FROM conversations")
      ApplicationRecord.connection.execute("DELETE FROM municipalities")
    end
    Current.reset
    @muni = ApplicationRecord.connected_to(role: :admin) do
      Municipality.create!(name: "Test City", slug: "test-#{SecureRandom.hex(4)}")
    end
    @channel = ApplicationRecord.connected_to(role: :admin) do
      MunicipalityChannel.create!(
        municipality: @muni, phone_number_id: "PNID123", waba_id: "WABA1",
        display_phone_number: "+5511999999999", access_token: "tok", active: true
      )
    end
  end

  after do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM processed_events")
      ApplicationRecord.connection.execute("DELETE FROM inbound_messages")
      ApplicationRecord.connection.execute("DELETE FROM unknown_channels")
      ApplicationRecord.connection.execute("DELETE FROM municipality_channels")
      ApplicationRecord.connection.execute("DELETE FROM conversations")
      ApplicationRecord.connection.execute("DELETE FROM municipalities")
    end
    Current.reset
  end

  let(:payload) do
    {
      "entry" => [{
        "changes" => [{
          "value" => {
            "metadata" => { "phone_number_id" => "PNID123" },
            "messages" => [{ "id" => "wamid.1", "from" => "+551188", "type" => "text", "text" => { "body" => "oi" } }]
          }
        }]
      }]
    }
  end

  it "persiste inbound carimbado com tenant" do
    expect { described_class.call(payload) }.to change {
      ApplicationRecord.connected_to(role: :admin) { InboundMessage.count }
    }.by(1)

    ApplicationRecord.connected_to(role: :admin) do
      inbound = InboundMessage.last
      expect(inbound.municipality_id).to eq(@muni.id)
      expect(inbound.message_id).to eq("wamid.1")
    end
  end

  it "phone_number_id desconhecido vai para unknown_channels" do
    payload["entry"][0]["changes"][0]["value"]["metadata"]["phone_number_id"] = "PNID_UNKNOWN"
    expect { described_class.call(payload) }.to change {
      ApplicationRecord.connected_to(role: :admin) { UnknownChannel.count }
    }.by(1)
    expect(ApplicationRecord.connected_to(role: :admin) { InboundMessage.count }).to eq(0)
  end

  it "reentrega do mesmo wamid não duplica" do
    described_class.call(payload)
    expect { described_class.call(payload) }.not_to change {
      ApplicationRecord.connected_to(role: :admin) { InboundMessage.count }
    }
  end
end
