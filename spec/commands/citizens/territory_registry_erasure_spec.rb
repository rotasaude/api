require "rails_helper"

# ADR 0042 (contrato §14 L13): quem tem QUALQUER versão de cadastro individual
# ou é o responsável de uma família é registro retido; o pedido nasce retido e
# a confirmação (Citizens::Erase) reconfere pela mesma regra.
RSpec.describe "Exclusão LGPD com cadastro territorial (ADR 0042)" do
  before { registry_city! }

  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)

  it "pedido de quem tem cadastro nasce retido" do
    patient, citizen = exam_patient!(21, age: 40, sex: "female")
    registry_registration!(patient: patient)
    expect(request_for(citizen).payload[:request].status).to eq("retained")
  end

  it "cadastro gravado depois do pedido: a confirmação retém e nada se apaga" do
    patient, citizen = exam_patient!(24, age: 40, sex: "female")
    request = request_for(citizen).payload[:request]
    expect(request.status).to eq("pending")
    registry_registration!(patient: patient)
    result = Citizens::Erase.call(request: request, by: care_admin!)
    expect(result.payload[:request].status).to eq("retained")
    expect(citizen.reload.erased_at).to be_nil
    expect(IndividualRegistrationVersion.where(patient_id: patient.id)).to exist
  end

  it "responsável de família sem cadastro individual também retém; sem nada, a exclusão segue" do
    patient, citizen = exam_patient!(22, age: 40, sex: "female")
    registry_family!(registry_household!, responsible: patient)
    expect(IndividualRegistrationVersion.where(patient_id: patient.id)).not_to exist
    expect(request_for(citizen).payload[:request].status).to eq("retained")
    _free, other = exam_patient!(23, age: 40, sex: "female")
    expect(request_for(other).payload[:request].status).to eq("pending")
  end

  it "responsável designado depois do pedido: a confirmação retém" do
    patient, citizen = exam_patient!(25, age: 40, sex: "female")
    request = request_for(citizen).payload[:request]
    registry_family!(registry_household!, responsible: patient)
    expect(Citizens::Erase.call(request: request, by: care_admin!).payload[:request].status).to eq("retained")
  end
end
