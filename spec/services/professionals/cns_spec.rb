require "rails_helper"

RSpec.describe Professionals::Cns do
  describe ".valid?" do
    %w[700000000000005 100000000000007 200123456789019 898000000000002 712345678901236 123456789012348].each do |cns|
      it("aceita #{cns}") { expect(described_class.valid?(cns)).to be(true) }
    end

    {
      "dígito verificador errado" => "712345678901237",
      "primeiro dígito fora de 1, 2, 7, 8, 9" => "312345678901236",
      "14 dígitos" => "70000000000000",
      "com letra" => "70000000000000a",
      "vazio" => "",
      "nil" => nil
    }.each do |label, cns|
      it("recusa #{label}") { expect(described_class.valid?(cns)).to be(false) }
    end
  end

  describe ".generate" do
    it "é válido, começa com 7 e é determinístico pela semente" do
      a = described_class.generate("curitiba:profissional")
      expect(a).to match(/\A7\d{14}\z/)
      expect(described_class.valid?(a)).to be(true)
      expect(described_class.generate("curitiba:profissional")).to eq(a)
      expect(described_class.generate("maringa:profissional")).not_to eq(a)
    end

    it "gera válidos para muitas sementes (cobre o caso de dígito 10)" do
      200.times { |i| expect(described_class.valid?(described_class.generate("s#{i}"))).to be(true) }
    end
  end

  it ".mask mostra só os 4 últimos" do
    expect(described_class.mask("712345678901236")).to eq("*** **** **** 1236")
    expect(described_class.mask(nil)).to be_nil
  end
end
