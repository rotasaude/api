require "rails_helper"

# ADR 0026 + ADR 0033 (spec §8): paciente com documento clínico é registro retido.
RSpec.describe Citizens::RequestErasure do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  it "par com documento clínico nasce retido" do
    unit = create_unit
    citizen = verified_citizen!(1)
    consultation = finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: citizen)
    ClinicalDocuments::Issue.call(kind: "attendance_declaration", content: {}, by: verifier!, attendance: consultation.attendance)
    allow(described_class).to receive(:attended?).and_return(false) # isola a regra nova da do atendimento
    result = described_class.call(cpf: citizen.cpf, document_checked: true, by: verifier!)
    expect(result.payload[:request].status).to eq("retained")
  end
end
