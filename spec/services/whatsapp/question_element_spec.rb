require "rails_helper"

RSpec.describe Whatsapp::QuestionElement do
  def step(answer_type:, options: nil)
    Protocols::Step.new(id: "s", prompt: "?", answer_type: answer_type, options: options)
  end

  it "boolean → 2 buttons with true/false ids and i18n titles" do
    r = described_class.for(step(answer_type: "boolean"), body: "Tosse?")
    expect(r.kind).to eq(:buttons)
    expect(r.body).to eq("Tosse?")
    expect(r.options.map { |o| o[:id] }).to eq(%w[true false])
    expect(r.options.map { |o| o[:title] }).to eq([I18n.t("whatsapp.btn_yes"), I18n.t("whatsapp.btn_no")])
  end

  it "enum with ≤3 options → buttons, id == option" do
    r = described_class.for(step(answer_type: "enum", options: %w[a b c]), body: "Q")
    expect(r.kind).to eq(:buttons)
    expect(r.options.map { |o| o[:id] }).to eq(%w[a b c])
  end

  it "enum with 4..10 options → list" do
    r = described_class.for(step(answer_type: "enum", options: (1..10).map(&:to_s)), body: "Q")
    expect(r.kind).to eq(:list)
    expect(r.options.size).to eq(10)
  end

  it "enum with >10 options → text" do
    r = described_class.for(step(answer_type: "enum", options: (1..11).map(&:to_s)), body: "Q")
    expect(r.kind).to eq(:text)
  end

  it "integer → text" do
    expect(described_class.for(step(answer_type: "integer"), body: "Q").kind).to eq(:text)
  end

  it "text → text" do
    expect(described_class.for(step(answer_type: "text"), body: "Q").kind).to eq(:text)
  end

  it "truncates a long option title but keeps the full id" do
    long = "x" * 30
    r = described_class.for(step(answer_type: "enum", options: [long, "b", "c"]), body: "Q")
    first = r.options.first
    expect(first[:id]).to eq(long)
    expect(first[:title].length).to eq(20)
    expect(first[:title]).to end_with("…")
  end
end
