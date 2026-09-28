require "rails_helper"

RSpec.describe Professionals::Cbo do
  it "toda entrada tem código de 6 dígitos único, título e conselho conhecido ou nulo" do
    codes = described_class.all.map(&:code)
    expect(codes).to all(match(/\A\d{6}\z/))
    expect(codes.uniq.size).to eq(codes.size)
    expect(described_class.all.map(&:title)).to all(be_present)
    expect(described_class.all.map(&:council).compact - Professional::COUNCILS).to be_empty
  end

  it "acha pelo código, com o conselho esperado" do
    expect(described_class.find("225125")).to have_attributes(title: "Médico clínico", council: "CRM")
    expect(described_class.find("999999")).to be_nil
  end

  it "toda entrada exige conselho (ACS/ACE voltam com CNES, ADR 0021 em aberto)" do
    expect(described_class.all.map(&:council)).to all(be_present)
  end

  it "active deixa de fora os deprecated" do
    expect(described_class.active).to all(have_attributes(deprecated: false))
  end
end
