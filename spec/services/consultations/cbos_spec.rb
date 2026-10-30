require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 1): quem registra cada tipo de consulta. MIAI
# fora de 2232 → geral; 2232* → odontológica (dentista); TSB/ASB → odontológica
# (auxiliar); o resto (técnico de enfermagem, protético) → nenhuma.
RSpec.describe Consultations::Cbos do
  {
    "225125" => [ "general" ], "223505" => [ "general" ], "223208" => [ "dental" ], "223212" => [ "dental" ],
    "322405" => [ "dental" ], "322415" => [ "dental" ], "322425" => [ "dental" ], "322430" => [ "dental" ],
    "322410" => [], "322205" => [], "" => []
  }.each do |cbo, kinds|
    it("kinds_for(#{cbo.inspect}) == #{kinds}") { expect(described_class.kinds_for(cbo)).to eq(kinds) }
  end

  it "papel odontológico: 2232* dentista, os quatro de nível técnico auxiliar, o resto nulo" do
    expect(described_class.role("223212")).to eq(:dentist)
    expect(described_class.role("223208")).to eq(:dentist)
    expect(described_class.role("322405")).to eq(:auxiliary)
    expect(described_class.role("322430")).to eq(:auxiliary)
    expect(described_class.role("225125")).to be_nil
    expect(described_class.role("322410")).to be_nil
  end

  it "allowed? sem kind continua a consulta comum (o dentista fica fora); com kind olha o tipo" do
    expect(described_class.allowed?("223208")).to be(false)
    expect(described_class.allowed?("225125")).to be(true)
    expect(described_class.allowed?("223208", kind: "dental")).to be(true)
    expect(described_class.allowed?("322430", kind: "dental")).to be(true)
    expect(described_class.allowed?("225125", kind: "dental")).to be(false)
    expect(described_class.allowed?("322430", kind: "general")).to be(false)
  end
end
