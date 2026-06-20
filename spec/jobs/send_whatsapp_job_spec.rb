require "rails_helper"

RSpec.describe SendWhatsappJob do
  let!(:muni) { create(:municipality) }
  let!(:channel) do
    ApplicationRecord.connected_to(role: :admin) do
      MunicipalityChannel.create!(municipality: muni, phone_number_id: "PNID", waba_id: "WABA",
                                  display_phone_number: "+551199", access_token: "tok", active: true)
    end
  end

  it "escopa MunicipalityChannel por município (escopo manual)" do
    outbound = instance_double(Whatsapp::Outbound, deliver_text: true)
    expect(Whatsapp::Outbound).to receive(:new).with(having_attributes(municipality_id: muni.id)).and_return(outbound)
    described_class.new.perform(to: "+5511988", body: "ola", municipality_id: muni.id)
  end

  it "levanta TenantMissing sem municipality_id" do
    expect {
      described_class.new.perform(to: "+5511988", body: "ola", municipality_id: nil)
    }.to raise_error(TenantScopedJob::TenantMissing)
  end
end
