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

  before do
    allow(Whatsapp::SessionWindow).to receive(:open?).and_return(true)
  end

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

  describe "24h window guard" do
    let(:client) { instance_double(Whatsapp::Outbound) }

    before do
      allow(Whatsapp::Outbound).to receive(:new).and_return(client)
      allow(client).to receive(:deliver_text).and_return(Whatsapp::Outbound::Result.new(status: 200, body: "{}"))
      allow(client).to receive(:deliver_interactive).and_return(Whatsapp::Outbound::Result.new(status: 200, body: "{}"))
      allow(client).to receive(:deliver_template).and_return(Whatsapp::Outbound::Result.new(status: 200, body: "{}"))
    end

    it "sends a template message via deliver_template (any window state)" do
      allow(Whatsapp::SessionWindow).to receive(:open?).and_return(false)
      msg = Messaging::Reply.template(name: "rota_saude_ask").to_h
      described_class.new.perform(to: "5511999", message: msg, municipality_id: muni.id)
      expect(client).to have_received(:deliver_template)
    end

    it "sends free-form text within the window" do
      allow(Whatsapp::SessionWindow).to receive(:open?).and_return(true)
      msg = Messaging::Reply.text("Olá").to_h
      described_class.new.perform(to: "5511999", message: msg, municipality_id: muni.id)
      expect(client).to have_received(:deliver_text)
    end

    it "substitutes the resume template for free-form outside the window" do
      allow(Whatsapp::SessionWindow).to receive(:open?).and_return(false)
      msg = Messaging::Reply.text("Olá").to_h
      described_class.new.perform(to: "5511999", message: msg, municipality_id: muni.id)
      expect(client).to have_received(:deliver_template) do |to:, reply:|
        expect(reply.name).to eq("rota_saude_resume")
      end
      expect(client).not_to have_received(:deliver_text)
    end
  end
end
