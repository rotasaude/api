require "rails_helper"

RSpec.describe Whatsapp::Outbound do
  let(:channel) { Struct.new(:phone_number_id, :access_token).new("PNID", "tok") }
  subject(:outbound) { described_class.new(channel) }

  it "builds a button interactive payload (id/title from the reply)" do
    reply = Messaging::Reply.buttons(body: "Tosse?", options: [
      { id: "true", title: "Sim" }, { id: "false", title: "Não" }
    ])
    payload = outbound.interactive_payload(to: "+55119", reply: reply)
    expect(payload[:type]).to eq("interactive")
    expect(payload[:interactive][:type]).to eq("button")
    expect(payload[:interactive][:body]).to eq(text: "Tosse?")
    buttons = payload[:interactive][:action][:buttons]
    expect(buttons.map { |b| b[:reply][:id] }).to eq(%w[true false])
    expect(buttons.first[:type]).to eq("reply")
  end

  it "builds a list interactive payload" do
    reply = Messaging::Reply.list(body: "Escolha", options: [{ id: "a", title: "A" }, { id: "b", title: "B" }])
    payload = outbound.interactive_payload(to: "+55119", reply: reply)
    expect(payload[:interactive][:type]).to eq("list")
    rows = payload[:interactive][:action][:sections].first[:rows]
    expect(rows.map { |r| r[:id] }).to eq(%w[a b])
    expect(payload[:interactive][:action][:button]).to eq(I18n.t("whatsapp.list_button"))
  end

  # F-01.6. Sem WebMock ligado no projeto: stuba Net::HTTP.start, que é a
  # camada que Outbound#post usa, e captura a requisição montada.
  describe "#deliver_text" do
    let(:http) { instance_double(Net::HTTP) }
    let(:response) { instance_double(Net::HTTPOK, code: "200", body: %({"messages":[{"id":"wamid.out"}]})) }
    let(:sent) { [] }

    before do
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request) { |req| sent << req; response }
    end

    it "POSTs the text payload to the channel's Graph messages endpoint with its Bearer token" do
      result = outbound.deliver_text(to: "5541999990000", body: "Olá")

      expect(Net::HTTP).to have_received(:start).with("graph.facebook.com", 443, use_ssl: true)
      req = sent.sole
      expect(req).to be_a(Net::HTTP::Post)
      expect(req.uri.to_s).to eq("https://graph.facebook.com/v19.0/PNID/messages")
      expect(req["Authorization"]).to eq("Bearer tok")
      expect(req["Content-Type"]).to eq("application/json")
      expect(JSON.parse(req.body)).to eq(
        "messaging_product" => "whatsapp", "to" => "5541999990000",
        "type" => "text", "text" => { "body" => "Olá" }
      )
      expect(result.status).to eq(200)
      expect(result.body).to include("wamid.out")
    end
  end

  describe "#template_payload" do
    let(:reply) { Messaging::Reply.template(name: "rota_saude_resume", params: ["Curitiba"]) }

    it "builds a type:template payload with name, language and body params" do
      payload = described_class.new(channel).template_payload(to: "5511999", reply: reply)
      expect(payload[:type]).to eq("template")
      expect(payload[:template][:name]).to eq("rota_saude_resume")
      expect(payload[:template][:language]).to eq({ code: "pt_BR" })
      params = payload[:template][:components].first[:parameters]
      expect(params).to eq([{ type: "text", text: "Curitiba" }])
    end

    it "emits empty components when there are no params" do
      reply = Messaging::Reply.template(name: "rota_saude_resume")
      payload = described_class.new(channel).template_payload(to: "5511999", reply: reply)
      expect(payload[:template][:components]).to eq([])
    end
  end
end
