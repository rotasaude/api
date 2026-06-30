require "rails_helper"

RSpec.describe Messaging::Reply do
  it "builds a text reply" do
    r = described_class.text("oi")
    expect(r.kind).to eq(:text)
    expect(r.body).to eq("oi")
    expect(r.options).to eq([])
    expect(r.text?).to be true
  end

  it "builds a buttons reply" do
    r = described_class.buttons(body: "Tosse?", options: [{ id: "true", title: "Sim" }, { id: "false", title: "Não" }])
    expect(r.kind).to eq(:buttons)
    expect(r.text?).to be false
    expect(r.options.first).to eq(id: "true", title: "Sim")
  end

  it "round-trips through to_h / from_h" do
    r = described_class.list(body: "X", options: [{ id: "a", title: "A" }])
    back = described_class.from_h(r.to_h)
    expect(back.kind).to eq(:list)
    expect(back.body).to eq("X")
    expect(back.options).to eq([{ id: "a", title: "A" }])
  end
end
