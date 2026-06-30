require "rails_helper"

RSpec.describe SendWhatsappJob do
  let!(:muni) { create(:municipality) }
  let!(:channel) do
    ApplicationRecord.connected_to(role: :admin) do
      MunicipalityChannel.create!(municipality: muni, phone_number_id: "PNID", waba_id: "WABA",
                                  display_phone_number: "+551199", access_token: "tok", active: true)
    end
  end

  def text_msg(body) = Messaging::Reply.text(body).to_h

  it "escopa MunicipalityChannel por município (escopo manual)" do
    deliver_result = Whatsapp::Outbound::Result.new(status: 200, body: '{"ok":true}')
    outbound = instance_double(Whatsapp::Outbound, deliver_text: deliver_result)
    expect(Whatsapp::Outbound).to receive(:new).with(having_attributes(municipality_id: muni.id)).and_return(outbound)
    described_class.new.perform(to: "+5511988", message: text_msg("ola"), municipality_id: muni.id)
    om = OutboundMessage.last
    expect(om.to).to eq("+5511988")
    expect(om.status).to eq(200)
  end

  it "dedup contra crash-retry: 2ª chamada idêntica não bate HTTP" do
    deliver_result = Whatsapp::Outbound::Result.new(status: 200, body: "ok")
    outbound = instance_double(Whatsapp::Outbound, deliver_text: deliver_result)
    expect(Whatsapp::Outbound).to receive(:new).once.and_return(outbound)
    described_class.new.perform(to: "+551188", message: text_msg("ola"), municipality_id: muni.id)
    described_class.new.perform(to: "+551188", message: text_msg("ola"), municipality_id: muni.id)
    expect(OutboundMessage.where(to: "+551188").count).to eq(1)
  end

  it "despacha interativo quando o reply tem botões" do
    deliver_result = Whatsapp::Outbound::Result.new(status: 200, body: "ok")
    outbound = instance_double(Whatsapp::Outbound)
    expect(outbound).to receive(:deliver_interactive).and_return(deliver_result)
    expect(Whatsapp::Outbound).to receive(:new).and_return(outbound)
    msg = Messaging::Reply.buttons(body: "Tosse?", options: [{ id: "true", title: "Sim" }, { id: "false", title: "Não" }]).to_h
    described_class.new.perform(to: "+551177", message: msg, municipality_id: muni.id)
    expect(OutboundMessage.where(to: "+551177").count).to eq(1)
  end

  it "levanta TenantMissing sem municipality_id" do
    expect {
      described_class.new.perform(to: "+5511988", message: text_msg("ola"), municipality_id: nil)
    }.to raise_error(TenantScopedJob::TenantMissing)
  end
end
