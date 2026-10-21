require "rails_helper"

# ADR 0039 (spec §8; regra única de api#84): procedimento realizado conta
# como registro clínico na exclusão do cadastro.
RSpec.describe Citizens::RequestErasure do
  before { billing_city! }

  it "quem tem procedimento realizado fica retido; sem ele, não" do
    unit = upa!
    patient, citizen = exam_patient!(exam_seq!)
    allow(described_class).to receive_messages(attended?: false, documented?: false)
    expect(described_class.retained?(Citizen.where(id: citizen.id), cpf: citizen.cpf)).to be(false)
    recorded_procedure!(unit: unit, professional: doctor!(unit), patient: patient)
    expect(described_class.retained?(Citizen.where(id: citizen.id), cpf: citizen.cpf)).to be(true)
  end

  it "procedimento CANCELADO ainda mantém o cidadão retido (E16)" do
    unit = upa!
    doctor = doctor!(unit)
    patient, citizen = exam_patient!(exam_seq!)
    allow(described_class).to receive_messages(attended?: false, documented?: false)
    procedure = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    Billing::Cancel.call(procedure: procedure, reason: "Lançado em duplicidade", by: doctor)
    expect(procedure.reload.status).to eq("cancelled")
    expect(described_class.retained?(Citizen.where(id: citizen.id), cpf: citizen.cpf)).to be(true)
  end
end
