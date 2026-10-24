require "rails_helper"

# "Validar nome" regras 4 e 5 na ficha: o paciente guarda o nome como digitado;
# a ficha leva o conjunto oficial (letras romanas, agudo/circunflexo/til/trema
# sobre vogal, apóstrofo reto, maiúsculas).
RSpec.describe Ledi::Fichas::LediName do
  it "converte para o conjunto oficial e passa no validador estrito" do
    {
      "Maria Gonçalves D’Ávila-Souza" => "MARIA GONCALVES D'ÁVILA SOUZA",
      "Àlvaro Muñoz" => "ALVARO MUNOZ",
      "joão  d‘ávila" => "JOÃO D'ÁVILA",
      "Inês Müller" => "INÊS MÜLLER",
      "Ana Maria S. Lima" => "ANA MARIA S LIMA"
    }.each do |typed, sent|
      expect(described_class.call(typed)).to eq(sent)
      expect(TerritoryRegistry::Dictionary.valid_name?(sent, strict: true)).to be(true), sent
    end
  end

  it "vazio vira nil" do
    expect([ described_class.call(nil), described_class.call("  "), described_class.call("--") ]).to eq([ nil, nil, nil ])
  end
end
