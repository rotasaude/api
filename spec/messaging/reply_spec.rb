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

  describe ".template" do
    it "builds a template reply with name and params" do
      r = Messaging::Reply.template(name: "rota_saude_resume", params: ["Curitiba"])
      expect(r.kind).to eq(:template)
      expect(r.template?).to be(true)
      expect(r.name).to eq("rota_saude_resume")
      expect(r.params).to eq(["Curitiba"])
    end

    it "defaults params to []" do
      expect(Messaging::Reply.template(name: "rota_saude_resume").params).to eq([])
    end

    it "round-trips through to_h/from_h" do
      r = Messaging::Reply.template(name: "rota_saude_resume", params: ["x"])
      back = Messaging::Reply.from_h(r.to_h)
      expect(back.kind).to eq(:template)
      expect(back.name).to eq("rota_saude_resume")
      expect(back.params).to eq(["x"])
    end

    it "leaves name nil / params [] for a text reply round-trip" do
      back = Messaging::Reply.from_h(Messaging::Reply.text("oi").to_h)
      expect(back.name).to be_nil
      expect(back.params).to eq([])
    end
  end
end
