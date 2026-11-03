require "rails_helper"

# Módulo 29, Task 19 (ADR 0047, Desvio 17; contrato §15 V12): notificação de
# ESAVI a partir da dose, pela vigilância do módulo 25.
RSpec.describe "Sala de vacina — ESAVI", type: :request do
  let!(:city) do
    vaccination_city!.tap do |city|
      cid10_release!
      sigtap_release!
      ciap2_release!(ScreeningHelpers::CIAP2)
      Surveillance::DiseaseList::Load.call
      Platform::Features.set!(city: city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
    end
  end
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:dose) { create_immunization!(room, vaccinator_user: vaccinator) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  def post_esavi(id = dose.id, query: "") = post("/vaccination/immunizations/#{id}/esavi#{query}", headers: json_headers)

  before { sign_in_as(vaccinator) }

  it "201 { notification_id }: esavi manual, com a dose, a unidade da sala e a trilha da pessoa" do
    post_esavi
    expect(response).to have_http_status(:created)
    expect(json_body.keys).to eq([ "notification_id" ])
    n = DiseaseNotification.find(json_body["notification_id"])
    expect([ n.disease_code, n.origin, n.immunization_id, n.health_unit_id, n.patient_id, n.notifier_user_id ])
      .to eq([ "esavi", "manual", dose.id, room.health_unit_id, dose.patient_id, vaccinator.id ])
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(1)
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "surveillance", "person_ref" => "patient:#{dose.patient_id}")
  end

  it "evento só com ids: nada de vacina, lote ou dose" do
    post_esavi
    events = DomainEvent.where(name: "disease_notification.created")
    expect(events.sole.payload).to eq("notification_id" => json_body["notification_id"], "immediate" => true)
    dumped = DomainEvent.all.map { |e| e.payload.to_json }.join
    expect(dumped).not_to include(dose.immunobiological_code.to_s + "\"", "lot_number")
  end

  it "já aberta → 200 com o mesmo id e existing: true; nada novo" do
    post_esavi
    first = json_body["notification_id"]
    expect { post_esavi }.not_to change { [ DiseaseNotification.count, DomainEvent.where(name: "disease_notification.created").count ] }
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("notification_id" => first, "existing" => true)
  end

  it "vigilância desligada → 403 feature_disabled com feature surveillance; nada gravado" do
    Platform::Features.set!(city: city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
    post_esavi
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "dose de outra sala, id inexistente ou malformado → 404" do
    sign_in_as(room_member!(vaccine_room!))
    post_esavi
    expect(response).to have_http_status(:not_found)
    post_esavi(SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    post_esavi("nao-e-uuid")
    expect(response).to have_http_status(:not_found)
    expect(DiseaseNotification.count).to eq(0)
  end

  it "papel surveillance, fora da sala → 201 (também em dose sem sala); sem equipe nem papel → 404" do
    sign_in_as(surveillance_officer!)
    post_esavi
    expect(response).to have_http_status(:created)
    expect(DiseaseNotification.find(json_body["notification_id"]).notifier_user_id).not_to eq(vaccinator.id)
    orphan = create_immunization!(room, vaccinator_user: vaccinator, vaccine_room: nil, transcription: true, stock_lot: nil,
                                        care_group: nil, route: nil, site: nil)
    post_esavi(orphan.id)
    expect(response).to have_http_status(:created)
    sign_in_as(staff_with("outro-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
    post_esavi
    expect(response).to have_http_status(:not_found)
  end

  it "transcrição sem sala → 404; transcrição da sala usa a unidade da sala" do
    orphan = create_immunization!(room, vaccinator_user: vaccinator, vaccine_room: nil, transcription: true, stock_lot: nil,
                                        care_group: nil, route: nil, site: nil)
    post_esavi(orphan.id)
    expect(response).to have_http_status(:not_found)
    transcribed = create_immunization!(room, vaccinator_user: vaccinator, transcription: true, stock_lot: nil, care_group: nil, route: nil, site: nil)
    post_esavi(transcribed.id)
    expect(response).to have_http_status(:created)
    expect(DiseaseNotification.find(json_body["notification_id"]).health_unit_id).to eq(room.health_unit_id)
  end

  it "dose cancelada → 409 immunization_cancelled" do
    dose.update_columns(cancelled_at: Time.current, cancelled_by_user_id: vaccinator.id, cancel_reason: "x")
    post_esavi
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "immunization_cancelled")
    expect(DiseaseNotification.count).to eq(0)
  end

  it "dado na query → 422" do
    post_esavi(query: "?patient_id=#{dose.patient_id}")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(DiseaseNotification.count).to eq(0)
  end
end
