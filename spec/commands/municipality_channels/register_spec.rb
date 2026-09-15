require "rails_helper"

# Registro do canal WhatsApp de uma cidade (Plano 4) — antes, parte do
# ProvisionMunicipality.
RSpec.describe MunicipalityChannels::Register do
  let(:city) { create(:city, status: "active") }
  let(:attrs) do
    { phone_number_id: "PN-#{SecureRandom.hex(3)}", waba_id: "WABA-1", display_phone_number: "+55 41 99999-0000",
      access_token: "tok-secreto" }
  end

  it "registers an active channel on the platform and audits it without token or phone" do
    result = described_class.call(city: city, **attrs)

    expect(result.ok?).to be(true)
    expect(result.payload[:channel]).to have_attributes(city_id: city.id, phone_number_id: attrs[:phone_number_id], active: true)
    expect(PlatformEvent.find_by!(name: "channel.registered").payload)
      .to eq("city_id" => city.id, "phone_number_id" => attrs[:phone_number_id])
  end

  it "refuses a city that is not active and writes nothing" do
    provisioning = create(:city, status: "provisioning")

    result = nil
    expect { result = described_class.call(city: provisioning, **attrs) }.not_to change(PlatformEvent, :count)
    expect(result.reason).to eq(:city_not_servable)
    expect(CityChannel.where(city: provisioning)).to be_empty
  end

  it "refuses an empty token and a phone_number_id that is already registered" do
    expect(described_class.call(city: city, **attrs.merge(access_token: "")).reason).to eq(:invalid)

    described_class.call(city: city, **attrs)
    expect(described_class.call(city: create(:city), **attrs).reason).to eq(:invalid)
    expect(CityChannel.where(phone_number_id: attrs[:phone_number_id]).count).to eq(1)
  end
end
