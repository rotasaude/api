require "rails_helper"

RSpec.describe Patients::AddCpf do
  before { clinical_city! }

  let(:by) { verifier! }
  let(:typed) { Patients::CreateTyped.call(attrs: { "full_name" => "Joao Pedro Silva", "birth_date" => "1990-02-03", "sex" => "male", "no_cpf_reason" => "8" }, by: by).payload[:patient] }

  it "recusa CPF de outro paciente (cpf_taken) sem mudar nada" do
    other, _citizen = exam_patient!(1, age: 40, sex: "male")
    expect(described_class.call(patient: typed, cpf: other.cpf, by: by).reason).to eq(:cpf_taken)
    expect(typed.reload.cpf).to be_nil
    expect(typed.no_cpf_reason).to eq("8")
  end

  it "liga o par validado do CPF e os dados validados substituem os digitados" do
    citizen = verified_citizen!(7, full_name: "João Pedro da Silva", sex: "male").tap { _1.update!(birth_date: "1990-02-03") }
    result = described_class.call(patient: typed, cpf: citizen.cpf, by: by)
    expect(result).to be_ok
    expect(citizen.reload.patient_id).to eq(typed.id)
    expect(typed.reload.full_name).to eq("João Pedro da Silva")
    expect(typed.no_cpf_reason).to be_nil
    event = DomainEvent.where(name: "patient.cpf_added").last
    expect(event.payload.keys).to match_array(%w[patient_id user_id])
  end

  it "CPF inválido não grava; paciente com CPF não troca" do
    expect(described_class.call(patient: typed, cpf: "11111111111", by: by).reason).to eq(:invalid_cpf)
    described_class.call(patient: typed, cpf: valid_cpf(55), by: by)
    expect(described_class.call(patient: typed.reload, cpf: valid_cpf(56), by: by).reason).to eq(:invalid_transition)
  end
end
