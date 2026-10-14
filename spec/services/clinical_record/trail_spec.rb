require "rails_helper"

RSpec.describe ClinicalRecord::Trail do
  it "extra nunca sobrescreve as chaves centrais da trilha" do
    patient = Struct.new(:id).new("patient-1")
    user = Struct.new(:id).new("user-1")
    grant = ClinicalRecord::Access::Grant.new(kind: :exam_result, opening: nil, reason: nil)
    expect(DomainEvents).to receive(:publish) do |_name, **payload|
      expect(payload).to include(patient_id: "patient-1", user_id: "user-1", access: "exam_result", exam_result_id: "r1")
    end
    described_class.viewed!(patient: patient, user: user, grant: grant,
                            extra: { user_id: "x", patient_id: "y", access: "z", exam_result_id: "r1" })
  end
end
