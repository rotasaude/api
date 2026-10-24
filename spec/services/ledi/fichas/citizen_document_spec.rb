require "rails_helper"

# Documento do cidadão nas fichas LEDI (módulo 24a): CPF; sem CPF, o CNS com
# stCidadaoNaoPossuiCpf e a justificativa (domínio JustificativaNaoPossuiCpf,
# o mesmo na FAI e na FCI). CPF e CNS nunca juntos.
RSpec.describe Ledi::Fichas::CitizenDocument do
  include TerritoryRegistryHelpers

  it "paciente com CPF: só o CPF" do
    patient = Patient.new(cpf: "52998224725", cns: "700000000000013")
    expect(described_class.for(patient)).to eq(cpf: "52998224725", cns: nil, no_cpf: false, justification: nil)
  end

  it "paciente sem CPF: o CNS, no_cpf e a justificativa como inteiro" do
    patient = Patient.new(cpf: nil, cns: "700000000000013", no_cpf_reason: "11")
    expect(described_class.for(patient)).to eq(cpf: nil, cns: "700000000000013", no_cpf: true, justification: 11)
  end

  it "paciente sem CPF e sem CNS: os dois nil (quem chama recusa patient_without_identifier)" do
    patient = Patient.new(cpf: "", cns: "", no_cpf_reason: "3")
    expect(described_class.for(patient)).to eq(cpf: nil, cns: nil, no_cpf: true, justification: 3)
  end
end
