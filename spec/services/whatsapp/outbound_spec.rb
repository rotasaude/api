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
end
