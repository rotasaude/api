require "rails_helper"

# Módulo 29, revisão final I2 (ruling da coordenação; Desvio 13; V7, V23): a
# forma <rnds> da dose na caderneta e no detalhe fala a mesma língua das
# pendências. "Envio desligado" é só o interruptor (`Rnds::Gate.enabled?`);
# dose ativa → entrada `application`; dose cancelada → entrada
# `cancellation` se existir, senão `not_sent` (nada mais vai à RNDS), com o
# `sent_at`/`accepted_at` da original preservados.
RSpec.describe "Sala de vacina — <rnds> da dose", type: :request do
  let!(:city) { vaccination_city!(rnds: true) }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  def card_rnds(dose)
    post "/vaccination/rooms/#{room.id}/card", params: { patient_id: dose.patient_id }.to_json, headers: json_headers
    expect(response).to have_http_status(:ok)
    json_body["immunizations"].find { |item| item["id"] == dose.id }.fetch("rnds")
  end

  def show_rnds(dose)
    get "/vaccination/immunizations/#{dose.id}"
    expect(response).to have_http_status(:ok)
    json_body.fetch("rnds")
  end

  def application(dose) = RndsOutboxEntry.find_by!(immunization_id: dose.id, kind: "application")
  def cancel!(dose) = Vaccination::CancelImmunization.call(immunization: dose, reason: "Paciente errado na busca", replacement: nil, by: lead)

  before { sign_in_as(vaccinator) }

  it "interruptor ligado com a credencial recusada: a dose segue pending (como nas pendências), não not_sent" do
    IntegrationCredential.find_by!(kind: "rnds").update_columns(last_check_status: "unauthorized")
    expect(Rnds::Gate.usable?(city)).to be(false)
    dose = record!(room, child, by: vaccinator)
    expect(card_rnds(dose)["status"]).to eq("pending")
    expect(show_rnds(dose)["status"]).to eq("pending")
  end

  it "interruptor desligado: pending vira not_sent" do
    Platform::Features.set!(city: city, key: "rnds_immunization", enabled: false, maintainer: ledi_maintainer!)
    dose = record!(room, child, by: vaccinator)
    expect(card_rnds(dose)["status"]).to eq("not_sent")
  end

  it "dose cancelada nunca tentada: not_sent, nunca pending para sempre" do
    dose = record!(room, child, by: vaccinator)
    expect(cancel!(dose)).to be_ok
    expect(RndsOutboxEntry.where(immunization_id: dose.id, kind: "cancellation")).to be_empty
    expect(card_rnds(dose)).to eq("status" => "not_sent", "sent_at" => nil, "accepted_at" => nil, "block_reason" => nil, "error" => nil)
    expect(show_rnds(dose)["status"]).to eq("not_sent")
  end

  it "dose cancelada com original recusado: not_sent com o sent_at da original preservado" do
    dose = record!(room, child, by: vaccinator)
    sent_at = 2.hours.ago.change(usec: 0)
    application(dose).update!(status: "rejected", error: "Recusada", first_attempt_at: sent_at, sent_at: sent_at)
    expect(cancel!(dose)).to be_ok
    rnds = card_rnds(dose)
    expect(rnds).to include("status" => "not_sent", "accepted_at" => nil, "error" => nil)
    expect(Time.iso8601(rnds["sent_at"]).to_i).to eq(sent_at.to_i)
  end

  it "dose cancelada de original aceita: mostra o andamento do cancelamento" do
    dose = record!(room, child, by: vaccinator)
    application(dose).update!(status: "accepted", accepted_at: Time.current, sent_at: Time.current, first_attempt_at: Time.current, rnds_id: "rnds-1")
    expect(cancel!(dose)).to be_ok
    expect(card_rnds(dose)["status"]).to eq("pending")
    RndsOutboxEntry.find_by!(immunization_id: dose.id, kind: "cancellation").update!(status: "failed", error: "Falhou")
    expect(card_rnds(dose)).to include("status" => "failed", "error" => "Falhou", "accepted_at" => nil)
    expect(show_rnds(dose)["status"]).to eq("failed")
  end
end
