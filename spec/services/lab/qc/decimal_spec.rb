require "rails_helper"

# Desvio 11: digitação com vírgula (ponto recusado); HL7 com ponto; saída com ponto, sem zeros à direita.
RSpec.describe Lab::Qc::Decimal do
  it "digitado: só vírgula, até 9 inteiros e 4 casas" do
    expect(described_class.typed("98,5")).to eq(BigDecimal("98.5"))
    expect(described_class.typed(" -0,0125 ")).to eq(BigDecimal("-0.0125"))
    expect(described_class.typed("100")).to eq(BigDecimal("100"))
    [ "98.5", "1.234", "1,23456", "1234567890", "", "abc", nil, 98.5 ].each { |raw| expect(described_class.typed(raw)).to be_nil }
  end

  it "HL7: só ponto" do
    expect(described_class.hl7("98.5")).to eq(BigDecimal("98.5"))
    [ "98,5", "1e3", "" ].each { |raw| expect(described_class.hl7(raw)).to be_nil }
  end

  it "saída" do
    expect(described_class.out(BigDecimal("98.5000"))).to eq("98.5")
    expect(described_class.out(BigDecimal("100.0"))).to eq("100")
    expect(described_class.out(nil)).to be_nil
  end
end
