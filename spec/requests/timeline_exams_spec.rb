require "rails_helper"

# A linha do tempo do profissional e o histórico do cidadão passam a ter o
# kind exam (contrato §10, A24/A29). Uma trilha por leitura (a do controlador).
RSpec.describe "Linha do tempo com exames", type: :request do
  before do
    exam_city!
    Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
  end

  it "profissional em contexto e cidadão validado veem o exame; kinds aceita exam" do
    unit = create_unit("UBS LT")
    doctor = doctor!(unit)
    patient, citizen = exam_patient!(exam_seq!)
    order = exam_order!(patient: patient, unit: unit, requester: doctor)
    consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    sign_in_as(doctor)
    viewed = DomainEvent.where(name: "clinical_record.viewed").count
    get "/attendance/timeline", params: { patient_id: patient.id, kinds: %w[exam] }
    expect(json_body["entries"].map { |e| [ e["kind"], e["detail_ref"] ] }).to eq([ [ "exam", { "type" => "exam_order", "id" => order.id } ] ])
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(viewed + 1)
    sign_in_citizen(citizen.phone)
    get "/citizen/history", params: { citizen_id: citizen.id, kinds: %w[exam] }
    expect(json_body["entries"].first).to include("kind" => "exam", "status" => "awaiting_schedule", "status_label" => "Pedido registrado",
                                                  "document" => nil)
  end
end
