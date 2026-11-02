require "rails_helper"

# Módulo 29 (contrato §10; §15 V10/V11, W4): a vacina na linha do tempo do
# profissional (/attendance/timeline) e no histórico do cidadão (/citizen/history).
RSpec.describe "Linha do tempo com vacinas", type: :request do
  before do
    vaccination_city!
    Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
  end

  it "profissional vê a dose (e a cancelada); cidadão validado vê só a ativa, com os campos nulos" do
    room = vaccine_room!
    doctor = doctor!(room.health_unit)
    patient, citizen = exam_patient!(exam_seq!)
    active = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-20 09:00:00"))
    gone = create_immunization!(room, patient: patient, applied_at: Time.zone.parse("2026-10-21 09:00:00"), cancelled_at: Time.current,
                                      cancelled_by_user: room_member!(room), cancel_reason: "Pessoa errada")
    consulting_attendance!(room.health_unit, citizen: citizen, doctor: doctor)

    sign_in_as(doctor)
    get "/attendance/timeline", params: { patient_id: patient.id, kinds: %w[vaccination] }
    expect(json_body["entries"].map { |e| [ e["detail_ref"], e["status"] ] })
      .to eq([ [ { "type" => "immunization", "id" => gone.id }, "cancelled" ], [ { "type" => "immunization", "id" => active.id }, "active" ] ])
    expect(json_body["entries"].first).to include("kind" => "vaccination", "summary" => nil, "title" => /\AVacina .+ — .+\z/)

    sign_in_citizen(citizen.phone)
    get "/citizen/history", params: { citizen_id: citizen.id, kinds: %w[vaccination] }
    expect(json_body["entries"].size).to eq(1)
    expect(json_body["entries"].first).to include("kind" => "vaccination", "id" => "vaccination:#{active.id}", "occurred_at" => active.applied_at.iso8601,
                                                  "unit" => { "name" => room.health_unit.name }, "professional_name" => nil, "status" => nil,
                                                  "summary" => nil, "document" => nil)
    expect(json_body["entries"].first).not_to have_key("detail_ref")
  end
end
