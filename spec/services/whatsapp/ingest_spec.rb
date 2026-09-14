require "rails_helper"

RSpec.describe Whatsapp::Ingest do
  # Two real, distinct cities (own physical databases) so "landed in the
  # right city" and "the other city got nothing" are two independently
  # provable claims, not a single connected_to(role: :admin) read that today
  # is a silent no-op returning whichever city is currently connected
  # (5c-1: ApplicationRecord IS the primary class, so connected_to(role:
  # :admin) never raises and never routes anywhere else).
  let(:city_a) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }
  let(:city_b) { create(:city, database_url: city_database_url("rota_saude_test_city_b")) }
  let!(:channel) do
    CityChannel.create!(city: city_a, phone_number_id: "PNID123", waba_id: "WABA1",
                        display_phone_number: "+5511999999999", access_token: "tok", active: true)
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

  it "persists the inbound in the channel's own city, and only there" do
    city_b # force creation so "the other city stayed at zero" is meaningful

    expect {
      described_class.call(payload)
    }.to change { CityConnection.with(city_a) { InboundMessage.count } }.by(1)

    expect(CityConnection.with(city_b) { InboundMessage.count }).to eq(0)
    expect(UnknownChannel.count).to eq(0)

    inbound = CityConnection.with(city_a) { InboundMessage.last }
    expect(inbound.message_id).to eq("wamid.1")
  end

  it "phone_number_id desconhecido vai para unknown_channels (plataforma), sem tocar nenhuma cidade" do
    payload["entry"][0]["changes"][0]["value"]["metadata"]["phone_number_id"] = "PNID_UNKNOWN"

    expect { described_class.call(payload) }.to change(UnknownChannel, :count).by(1)

    expect(CityConnection.with(city_a) { InboundMessage.count }).to eq(0)
    expect(CityConnection.with(city_b) { InboundMessage.count }).to eq(0)
    # Fix round 1 (I2): city_a/city_b are random-slug Cities — their own
    # sessions cannot see a write on a DIFFERENT connection (5c-3 fix round 1
    # harness note in city_test_databases.rb). The harness's own default
    # connection (TEST_CITY_A, opened by the outer around) is a third,
    # separate session that neither check above reads — assert it too, or a
    # stray write there would go unnoticed.
    expect(InboundMessage.count).to eq(0)
  end

  it "reentrega do mesmo wamid não duplica na cidade" do
    described_class.call(payload)
    expect {
      described_class.call(payload)
    }.not_to change { CityConnection.with(city_a) { InboundMessage.count } }
  end
end
