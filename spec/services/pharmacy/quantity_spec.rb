require "rails_helper"

# Módulo 27a (ADR 0045): a quantidade é String decimal com ponto, como no papel.
RSpec.describe Pharmacy::Quantity do
  describe ".parse" do
    it "aceita inteiros e até duas casas com ponto" do
      expect(described_class.parse("30")).to eq(BigDecimal("30"))
      expect(described_class.parse("2.5")).to eq(BigDecimal("2.5"))
      expect(described_class.parse("0.25")).to eq(BigDecimal("0.25"))
      expect(described_class.parse("99999.99")).to eq(BigDecimal("99999.99"))
    end

    it "recusa vírgula, número JSON, três casas, sinal, excesso e espaço, sem arredondar" do
      ["1,5", 1.5, 3, nil, "0.001", "-2", "+2", "100000", "0", "0.00", " 3", "3 ", "3\n", "", "1e2", ".5", "5."].each do |raw|
        expect(described_class.parse(raw)).to be_nil, "esperava nil para #{raw.inspect}"
      end
    end

    it "aceita zero só com allow_zero" do
      expect(described_class.parse("0", allow_zero: true)).to eq(0)
      expect(described_class.parse("0.00", allow_zero: true)).to eq(0)
      expect(described_class.parse("-0", allow_zero: true)).to be_nil
      expect(described_class.parse("1,5", allow_zero: true)).to be_nil
    end
  end

  describe ".dump" do
    it "sempre com duas casas e ponto" do
      expect(described_class.dump(BigDecimal("30"))).to eq("30.00")
      expect(described_class.dump(BigDecimal("2.5"))).to eq("2.50")
      expect(described_class.dump(BigDecimal("0.25"))).to eq("0.25")
      expect(described_class.dump(BigDecimal("0"))).to eq("0.00")
      expect(described_class.dump(BigDecimal("99999.99"))).to eq("99999.99")
    end
  end
end
