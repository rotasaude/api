require "rails_helper"

# C-E9: JSON e HL7 com ponto; saída com ponto, sem zeros à direita.
RSpec.describe Lab::Qc::Decimal do
  it "JSON: string com ponto, até 9 inteiros e 4 casas" do
    expect(described_class.json("98.5")).to eq(BigDecimal("98.5"))
    expect(described_class.json("-2.0")).to eq(BigDecimal("-2.0"))
    expect(described_class.json("100")).to eq(BigDecimal("100"))
    [ "98,5", " 98.5", "1234567890", "1.12345", "abc", "", nil, 98.5 ].each { |raw| expect(described_class.json(raw)).to be_nil }
  end

  it "HL7: mesma regra do JSON" do
    expect(described_class.hl7("98.5")).to eq(BigDecimal("98.5"))
    [ "98,5", "1e3", "" ].each { |raw| expect(described_class.hl7(raw)).to be_nil }
  end

  it "saída" do
    expect(described_class.out(BigDecimal("98.5000"))).to eq("98.5")
    expect(described_class.out(BigDecimal("100.0"))).to eq("100")
    expect(described_class.out(nil)).to be_nil
  end
end
