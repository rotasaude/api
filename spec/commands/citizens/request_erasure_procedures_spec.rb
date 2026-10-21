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
end
