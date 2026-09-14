require "rails_helper"

RSpec.describe CityChannel do
  let(:city) do
    City.create!(slug: "canaltest", name: "Canal", status: "active",
                 database_url: city_database_url("rota_saude_test_city_a"),
                 encryption_key: SecureRandom.hex(32))
  end

  it "routes a phone_number_id to its city without a city connection" do
    described_class.create!(city: city, phone_number_id: "pn-1", waba_id: "w-1",
                            display_phone_number: "+55 41 0000-0000",
                            access_token: "segredo", active: true)

    found = described_class.active.find_by(phone_number_id: "pn-1")
    expect(found.city_id).to eq(city.id)
  end

  it "encrypts the access token at rest" do
    channel = described_class.create!(city: city, phone_number_id: "pn-2", waba_id: "w-2",
                                      display_phone_number: "+55 41 0000-0001",
                                      access_token: "segredo", active: true)
    raw = described_class.connection.select_value(
      described_class.sanitize_sql(["SELECT access_token FROM city_channels WHERE id = ?", channel.id])
    )
    expect(raw).not_to eq("segredo")
    expect(described_class.find(channel.id).access_token).to eq("segredo")
  end

  it "lives in the platform database, not a city database" do
    expect(described_class.connection_db_config.database).to match(/platform/)
  end
end
