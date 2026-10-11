require "rails_helper"

# Iniciais do paciente (ADR 0033, página /v; card api#51, lista de rascunhos
# órfãos): uma letra por palavra, sem as partículas; nunca o nome.
RSpec.describe Patients::Initials do
  it "uma letra maiúscula com ponto por palavra, sem partículas" do
    expect(described_class.call("Maria Aparecida da Silva")).to eq("M.A.S.")
    expect(described_class.call("joão DOS santos e souza")).to eq("J.S.S.")
  end

  it "nome vazio ou nil vira string vazia" do
    expect(described_class.call(nil)).to eq("")
    expect(described_class.call("   ")).to eq("")
  end
end
