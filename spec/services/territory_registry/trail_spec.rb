require "rails_helper"

# Contrato §14 L11 (ruling C11): a trilha do cadastro territorial é o
# clinical_record.viewed do 19a, access territory_registry, só ids.
RSpec.describe TerritoryRegistry::Trail do
  before { registry_city! }

  let(:user) { registry_acs! }

  it "pessoa mostrada: uma trilha com person_ref, sem evento novo" do
    patient = registry_patient!
    described_class.person_viewed!(user: user, patient_id: patient.id)
    described_class.person_viewed!(user: user, patient_id: nil, citizen_id: "c-1")
    payloads = DomainEvent.where(name: "clinical_record.viewed").order(:created_at).last(2).map(&:payload)
    expect(payloads.first).to eq("patient_id" => patient.id, "user_id" => user.id, "access" => "territory_registry", "reason_code" => nil,
                                 "person_ref" => "patient:#{patient.id}")
    expect(payloads.last).to include("patient_id" => nil, "person_ref" => "citizen:c-1")
  end
end
