require "rails_helper"

# Módulo 29, Task 9 (ADR 0047, Desvios 12 e 13; contrato §5; §15 V7, V8;
# dashboard D10): pendências do envio à RNDS da sala, sem nome.
RSpec.describe "Sala de vacina — pendências do envio", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city!(rnds: true) }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:base) { "/vaccination/rooms/#{room.id}/pending" }

  def child = vaccine_patient!(birth_date: Date.current - 61)

  # Dose com a entrada `application` criada `hours` atrás (prazo applied_at + 24 h).
  def dose_with_entry(hours:, status: "pending", **entry)
    travel_to(hours.hours.ago) { record!(room, child, applied_at: Time.current.iso8601) }.tap do |dose|
      RndsOutboxEntry.find_by(immunization_id: dose.id, kind: "application").update!(status: status, **entry) unless status == "pending" && entry.empty?
    end
  end

  def ids = json_body["items"].map { |item| item["immunization_id"] }

  before { sign_in_as(vaccinator) }

  it "pending há 21 h entra; há 19 h não; blocked entra com o motivo; sem nome nem CPF; forma D10 e counts" do
    old = dose_with_entry(hours: 21)
    dose_with_entry(hours: 19)
    blocked = dose_with_entry(hours: 1, status: "blocked", block_reason: "patient_without_cns_or_cpf")
    dose_with_entry(hours: 2, status: "accepted", accepted_at: Time.current)
    get base
    expect(response).to have_http_status(:ok)
    expect(ids).to eq([ blocked.id, old.id ])
    expect(json_body["items"].first).to eq("immunization_id" => blocked.id, "patient_id" => blocked.patient_id,
                                           "immunobiological" => { "code" => "42", "name" => "Vacina penta (DTP/HB/Hib)" },
                                           "applied_at" => blocked.applied_at.as_json,
                                           "rnds" => { "status" => "blocked", "sent_at" => nil, "accepted_at" => nil,
                                                       "block_reason" => "patient_without_cns_or_cpf", "error" => nil })
    expect(json_body["counts"]).to eq("blocked" => 1, "rejected" => 0, "failed" => 0, "late" => 0)
    expect(json_body["next_before"]).to be_nil
    patient = Patient.find(old.patient_id)
    expect(response.body).not_to include(patient.full_name, patient.cpf, patient.cns)
  end

  it "counts.late conta só as não aceitas que passaram de deadline_at" do
    dose_with_entry(hours: 25)
    dose_with_entry(hours: 26, status: "rejected", error: "Recusada")
    dose_with_entry(hours: 27, status: "accepted", accepted_at: Time.current)
    dose_with_entry(hours: 23)
    get base
    expect(json_body["counts"]).to eq("blocked" => 0, "rejected" => 1, "failed" => 0, "late" => 2)
    expect(json_body["items"].size).to eq(3)
  end

  it "V7: dose cancelada com original recusado sai das pendências; cancelada com original aceito mostra o cancelamento" do
    rejected = dose_with_entry(hours: 2, status: "rejected", error: "Recusada")
    accepted = dose_with_entry(hours: 30, status: "accepted", accepted_at: Time.current)
    lead = room_member!(room, role: "room_lead", cbo: "223505")
    [ rejected, accepted ].each { |dose| Vaccination::CancelImmunization.call(immunization: dose, reason: "Paciente errado na busca", replacement: nil, by: lead) }
    RndsOutboxEntry.find_by(immunization_id: accepted.id, kind: "cancellation").update!(status: "failed", error: "Falhou")
    get base
    expect(ids).to eq([ accepted.id ])
    expect(json_body.dig("items", 0, "rnds", "status")).to eq("failed")
    expect(json_body["counts"]).to include("rejected" => 0, "failed" => 1)
  end

  it "envio desligado: pending vira not_sent e fica fora da lista e do atraso; blocked/rejected continuam" do
    Platform::Features.set!(city: city, key: "rnds_immunization", enabled: false, maintainer: ledi_maintainer!)
    dose_with_entry(hours: 30)
    rejected = dose_with_entry(hours: 30, status: "rejected", error: "Recusada")
    get base
    expect(ids).to eq([ rejected.id ])
    expect(json_body["counts"]).to eq("blocked" => 0, "rejected" => 1, "failed" => 0, "late" => 1)
  end

  it "pagina com limit e next_before" do
    doses = (1..3).map { |n| dose_with_entry(hours: n, status: "blocked", block_reason: "patient_without_cns_or_cpf") }
    get base, params: { limit: 2 }
    expect(ids).to eq(doses.first(2).map(&:id))
    get base, params: { limit: 2, before: json_body["next_before"] }
    expect(ids).to eq([ doses.last.id ])
    expect(json_body["next_before"]).to be_nil
    expect(json_body["counts"]["blocked"]).to eq(3)
  end

  it "cursor ou limit inválidos → 422; chave estranha na query → 422" do
    get base, params: { before: "x" }
    expect(json_body).to include("error" => "invalid_cursor", "path" => "before")
    get base, params: { limit: 0 }
    expect(json_body).to include("error" => "invalid_limit", "path" => "limit")
    get base, params: { patient_id: SecureRandom.uuid }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "vacinador de outra sala → 403; sala inexistente → 404; sem trilha" do
    sign_in_as(room_member!(vaccine_room!))
    get base
    expect(response).to have_http_status(:forbidden)
    get "/vaccination/rooms/#{SecureRandom.uuid}/pending"
    expect(response).to have_http_status(:not_found)
    expect(DomainEvent.where(name: "clinical_record.viewed").where("occurred_at > ?", 1.minute.ago).count).to eq(0)
  end
end
