require "rails_helper"

# Valores fixados 2; Review Focus 5: endereço digitado por gente.
RSpec.describe ClinicalDocuments::Address do
  let(:base) { ControlledPrescriptionHelpers::ADDRESS }

  it "aceita só os formatos do esquema; apara espaços; complemento só com espaço vira ausente" do
    address, field = described_class.normalize(base.merge("street" => "  Rua  das Araucárias ", "complement" => " "))
    expect(field).to be_nil
    expect(address).to eq(base)
    expect(address).not_to have_key("complement")
  end

  it "número aceita s/n" do
    address, field = described_class.normalize(base.merge("number" => "s/n"))
    expect(field).to be_nil
    expect(address["number"]).to eq("s/n")
  end

  it "máscara é recusada com o campo: CEP com hífen ou ponto, UF minúscula (Review Focus 5)" do
    expect(described_class.normalize(base.merge("zip" => "80010-000"))).to eq([ nil, "zip" ])
    expect(described_class.normalize(base.merge("zip" => "80.010000"))).to eq([ nil, "zip" ])
    expect(described_class.normalize(base.merge("uf" => "pr"))).to eq([ nil, "uf" ])
  end

  it "devolve o campo exato que falhou" do
    expect(described_class.normalize(base.merge("zip" => "8001000"))).to eq([ nil, "zip" ])
    expect(described_class.normalize(base.merge("uf" => "XX"))).to eq([ nil, "uf" ])
    expect(described_class.normalize(base.except("district"))).to eq([ nil, "district" ])
    expect(described_class.normalize(base.merge("street" => "x" * 121))).to eq([ nil, "street" ])
    expect(described_class.normalize(base.merge("complement" => "c" * 61))).to eq([ nil, "complement" ])
    expect(described_class.normalize("rua tal")).to eq([ nil, "address" ])
  end

  it "caractere de controle em qualquer campo de texto é recusado com o campo (FW5); quebra de linha vira espaço" do
    %w[street number district city complement].each do |key|
      expect(described_class.normalize(base.merge(key => "A\u0000B"))).to eq([ nil, key ])
      expect(described_class.normalize(base.merge(key => "A\u0007B"))).to eq([ nil, key ])
      expect(described_class.normalize(base.merge(key => "AB\u0000"))).to eq([ nil, key ]) # o strip comeria o NUL final
    end
    address, field = described_class.normalize(base.merge("street" => "Rua das\nAraucárias"))
    expect([ address["street"], field ]).to eq([ "Rua das Araucárias", nil ])
  end

  it "telefone só com dígitos (10 ou 11); acento e emoji passam (o PDF troca o que não tem)" do
    expect(described_class.phone("41999990000")).to eq("41999990000")
    expect(described_class.phone("4133330000")).to eq("4133330000")
    expect(described_class.phone("(41) 99999-0000")).to be_nil
    expect(described_class.phone("4133")).to be_nil
    expect(described_class.phone(4_133_330_000)).to be_nil
    address, = described_class.normalize(base.merge("street" => "Rua São João 🌳"))
    expect(described_class.line(address)).to eq("Rua São João 🌳, 120 — Centro — Curitiba/PR — CEP 80010-000")
  end
end
