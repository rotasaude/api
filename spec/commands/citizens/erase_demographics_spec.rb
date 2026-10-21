require "rails_helper"

# D-U1 + ADR 0026: na exclusão confirmada (pessoa sem registro clínico), o
# paciente perde raça/cor, etnia e endereço junto com o par.
RSpec.describe Citizens::Erase do
  before { billing_city! }

  it "apaga os campos do paciente não retido" do
    patient, citizen = exam_patient!(exam_seq!)
    patient.update!(BillingHelpers::DEMOGRAPHICS)
    reception = staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: reception).payload[:request]
    expect(request.status).to eq("pending")
    result = described_class.call(request: request, by: staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
    expect(result.payload[:request].status).to eq("confirmed")
    expect(patient.reload.slice(*Patient::DEMOGRAPHICS).values.compact).to eq([])
  end
end
