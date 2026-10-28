require "rails_helper"

# Contrato §15 K8 e Desvio 11: a trilha da vigilância é o clinical_record.viewed
# do 19a, access surveillance, sem evento novo e só com ids.
RSpec.describe Surveillance::Trail do
  before { surveillance_city! }

  let(:user) { surveillance_officer! }

  it "pessoa mostrada: uma trilha com person_ref" do
    patient = surveillance_patient!(51)
    described_class.person_viewed!(user: user, patient_id: patient.id)
    described_class.person_viewed!(user: user, patient_id: nil, citizen_id: "c-1")
    payloads = DomainEvent.where(name: "clinical_record.viewed").order(:created_at).last(2).map(&:payload)
    expect(payloads.first).to eq("patient_id" => patient.id, "user_id" => user.id, "access" => "surveillance", "reason_code" => nil,
                                 "person_ref" => "patient:#{patient.id}")
    expect(payloads.last).to include("patient_id" => nil, "person_ref" => "citizen:c-1")
  end

  it "lista: um evento por requisição, só os ids das notificações" do
    ids = [ SecureRandom.uuid, SecureRandom.uuid ]
    expect { described_class.listed!(user: user, notification_ids: ids) }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:created_at).last.payload)
      .to eq("access" => "surveillance", "notification_ids" => ids, "user_id" => user.id)
  end
end
