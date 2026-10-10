require "rails_helper"

# COFEN 801/2026 (receita de enfermagem leva o CNPJ da instituição). DV pelo
# módulo 11; formato alfanumérico da IN RFB 2.229/2024 (valor de cada
# caractere = código ASCII − 48), com o exemplo oficial da Receita.
RSpec.describe Cnpj do
  it "aceita CNPJ numérico e alfanumérico válidos, com ou sem pontuação" do
    expect(described_class.normalize("11.222.333/0001-81")).to eq("11222333000181")
    expect(described_class.normalize("76001234000115")).to eq("76001234000115")
    expect(described_class.normalize("12.ABC.345/01DE-35")).to eq("12ABC34501DE35")
    expect(described_class.normalize("12abc34501de35")).to eq("12ABC34501DE35")
  end

  it "recusa DV errado, tamanho errado, repetidos e lixo" do
    [ "11222333000182", "1122233300018", "00000000000000", "AAAAAAAAAAAA00", "", nil, 123, "11.222.333/0001-8X" ].each do |value|
      expect(described_class.normalize(value)).to be_nil, value.inspect
    end
  end

  it "calcula os dígitos e formata" do
    expect(described_class.with_check_digits("760012340001")).to eq("76001234000115")
    expect(described_class.display("76001234000115")).to eq("76.001.234/0001-15")
  end
end
