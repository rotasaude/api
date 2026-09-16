require "rails_helper"

RSpec.describe "CityConnection encryption context" do
  let!(:city_a) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }
  let!(:city_b) { create(:city, database_url: city_database_url("rota_saude_test_city_b")) }

  it "sets Current.city for the block" do
    expect(CityConnection.with(city_a) { Current.city&.slug }).to eq(city_a.slug)
  end

  # InboundMessage exige from e kind (validação + NOT NULL) e `raw` é coluna de
  # texto: passe String, não Hash.
  it "round-trips a non-deterministic attribute inside the city" do
    id = CityConnection.with(city_a) do
      InboundMessage.create!(message_id: "wamid-#{SecureRandom.hex(4)}", from: "+5541999990000",
                             kind: "text", raw: '{"t":"oi"}').id
    end
    expect(CityConnection.with(city_a) { InboundMessage.find(id).raw }).to eq('{"t":"oi"}')
  end

  it "round-trips a deterministic attribute and keeps the lookup working" do
    CityConnection.with(city_a) { Conversation.create!(phone: "+5541999990002", state: :greeting) }

    expect(CityConnection.with(city_a) { Conversation.where(phone: "+5541999990002").count }).to eq(1)
  end

  it "does not decrypt a row of city A with city B's material" do
    id = CityConnection.with(city_a) do
      InboundMessage.create!(message_id: "wamid-#{SecureRandom.hex(4)}", from: "+5541999990001",
                             kind: "text", raw: '{"t":"segredo"}').id
    end
    raw = CityConnection.with(city_a) do
      InboundMessage.connection.select_value(InboundMessage.sanitize_sql(["SELECT raw FROM inbound_messages WHERE id = ?", id]))
    end

    expect {
      ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(city_b)) do
        ActiveRecord::Encryption.encryptor.decrypt(raw)
      end
    }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
  end

  it "does not match a deterministic value written by the other city" do
    CityConnection.with(city_a) { Conversation.create!(phone: "+5541999990003", state: :greeting) }

    expect(CityConnection.with(city_b) { Conversation.where(phone: "+5541999990003").count }).to eq(0)
  end

  # Hazard: ActiveRecord::Encryption.with_encryption_context is per-thread and
  # global, not per-model. Platform-owned encrypted attributes (City#database_url,
  # City#encryption_key, CityChannel#access_token, Operator#otp_secret) are read
  # and written from *inside* CityConnection.with (e.g. SendWhatsappJob reads
  # CityChannel#access_token while running in the city's block). Prove the
  # platform ciphertext survives being read/written under a city's context.
  it "reads a platform attribute written outside any city context from inside a city block" do
    channel = CityChannel.create!(city: city_a, phone_number_id: "PNID-#{SecureRandom.hex(4)}",
                                  waba_id: "WABA1", display_phone_number: "+5541999990010",
                                  access_token: "platform-token-outside")

    expect(CityConnection.with(city_a) { CityChannel.find(channel.id).access_token })
      .to eq("platform-token-outside")
  end

  it "reads a platform attribute written inside a city block from outside any city context" do
    channel_id = CityConnection.with(city_a) do
      CityChannel.create!(city: city_a, phone_number_id: "PNID-#{SecureRandom.hex(4)}",
                          waba_id: "WABA2", display_phone_number: "+5541999990011",
                          access_token: "platform-token-inside").id
    end

    expect(CityChannel.find(channel_id).access_token).to eq("platform-token-inside")
  end
end
