require "rails_helper"

# Spec §8 / ADR 0037: a requisição do laboratório municipal conta como
# registro clínico na exclusão (regra única RequestErasure.retained?, api#84).
RSpec.describe Citizens::RequestErasure do
  before { lab_city! }

  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }
  let(:provider) { lab_provider! }

  # O exame do 21a de lab_requisition_row! nasce para outro paciente: só a
  # requisição prende o paciente da pessoa.
  def requisition_for!(patient)
    req = lab_requisition_row!(provider: provider, version: lab_exam!(provider: provider).current_version)
    req.update_columns(patient_id: patient.id) # rubocop:disable Rails/SkipsModelValidations -- liga a requisição ao paciente da pessoa
    req
  end

  it "quem tem requisição do laboratório fica retido" do
    patient, citizen = exam_patient!(exam_seq!)
    requisition_for!(patient)
    expect(ExamOrder.where(patient_id: patient.id)).to be_empty
    expect(described_class.retained?(Citizen.where(id: citizen.id), cpf: citizen.cpf)).to be(true)
  end

  it "o pedido de exclusão nasce retido" do
    patient, citizen = exam_patient!(exam_seq!)
    requisition_for!(patient)
    allow(described_class).to receive_messages(attended?: false, documented?: false)
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception)
    expect(result.payload[:request].status).to eq("retained")
  end

  it "sem requisição nem exame a pessoa não é retida" do
    _patient, citizen = exam_patient!(exam_seq!)
    expect(described_class.retained?(Citizen.where(id: citizen.id), cpf: citizen.cpf)).to be(false)
  end

  it "Erase reconfere: requisição aberta depois do pedido retém na confirmação" do
    patient, citizen = exam_patient!(exam_seq!)
    request = described_class.call(cpf: citizen.cpf, document_checked: true, by: reception).payload[:request]
    expect(request.status).to eq("pending")
    requisition_for!(patient)
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    result = Citizens::Erase.call(request: request, by: admin)
    expect(result.payload[:request]).to have_attributes(status: "retained", decided_by_user_id: admin.id)
    expect(citizen.reload.cpf).to be_present
  end
end
