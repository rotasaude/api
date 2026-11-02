require "rails_helper"

# Módulo 29, Task 9 (ADR 0047; contrato §5; §15 V14, V19): transcrição da
# caderneta pela rota da sala.
RSpec.describe "Sala de vacina — transcrição", type: :request do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61) }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:base) { "/vaccination/rooms/#{room.id}/transcriptions" }
  let(:item) { { immunobiological_code: "15", dose_code: "9", applied_on: (Date.current - 55).iso8601, lot_number: "BCG123", place: "Maternidade" } }

  def post_transcription(body) = post(base, params: body.to_json, headers: json_headers)

  before { sign_in_as(vaccinator) }

  it "201 { immunizations, card }; conferência transcribed; uma trilha" do
    post_transcription(patient_id: child.id, items: [ item ], close_check: true)
    expect(response).to have_http_status(:created)
    expect(json_body["immunizations"].sole).to include("transcription" => true, "status" => "active", "can_cancel" => true,
                                                       "lot" => { "id" => nil, "number" => "BCG123", "manufacturer" => { "code" => nil, "name" => nil },
                                                                  "expires_on" => nil })
    expect(json_body["card"]["checked"]).to include("mode" => "transcribed")
    expect(json_body["card"]["patient"]["id"]).to eq(child.id)
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(1)
  end

  it "422 com todos os problems; paciente ausente → 422; inexistente → 404; dado na query → 422" do
    post_transcription(patient_id: child.id, items: [ item.merge(applied_on: (Date.current + 1).iso8601) ], close_check: false)
    expect(json_body).to eq("error" => "applied_on_in_future", "path" => "items[0].applied_on",
                            "problems" => [ { "path" => "items[0].applied_on", "error" => "applied_on_in_future" } ])
    post_transcription(items: [ item ], close_check: false)
    expect(json_body).to include("path" => "patient_id")
    post_transcription(patient_id: SecureRandom.uuid, items: [ item ], close_check: false)
    expect(response).to have_http_status(:not_found)
    post("#{base}?patient_id=#{child.id}", params: { items: [ item ], close_check: false }.to_json, headers: json_headers)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Immunization.count).to eq(0)
  end

  it "fora da equipe da sala → 403" do
    sign_in_as(room_member!(vaccine_room!))
    post_transcription(patient_id: child.id, items: [ item ], close_check: false)
    expect(response).to have_http_status(:forbidden)
  end
end
