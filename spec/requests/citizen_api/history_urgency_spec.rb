require "rails_helper"

# "Meu histórico" do wpda com a urgência (ADR 0050; contrato §10 e §14 Q13,
# Q25): o cidadão do CPF vê o atendimento de urgência fechado pela UPA, pela
# chegada e pelo desfecho em texto simples, com `return_guidance` sem o motivo;
# nunca CID, cor, queixa, critério, óbito nem registro por engano; a visita
# não sai duas vezes (nem atendimento, nem consulta); o documento do walk_in
# (sem cidadão) aparece e baixa.
RSpec.describe "Histórico do cidadão com a urgência", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa!(name: "UPA Cajuru") }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:patient) { urgency_patient!(7) }
  let(:phone) { "+5541988887007" }
  def body = JSON.parse(response.body)

  before do
    timeline_city!(documents: true)
    urgency_protocol!
    ciap2_release!; cid10_release!; sigtap_release!
    Citizen.create!(cpf: patient.cpf, phone: phone, verification_level: "verified", patient_id: patient.id)
  end

  def closed!(kind, attrs = {})
    e = arrived!(upa, patient: patient).tap { |x| classified!(x, color: "orange", by: nurse, pain_scale: 9) }
    called!(e, by: doctor)
    finalized_urgency!(e, doctor: doctor, cid10: "I10")
    result = Urgency::RecordOutcome.call(encounter: e.reload, attrs: { "kind" => kind }.merge(attrs), by: doctor)
    raise "desfecho recusado: #{result.reason}" if result.failure?

    e.reload
  end

  it "traz a urgência fechada sem CID, cor, queixa nem critério; óbito, engano e aberto ficam fora; o documento do walk_in baixa" do
    shown = closed!("discharged_to_primary_care", "return_guidance" => { "days" => 3, "reason" => "Reavaliar pressão arterial" })
    death = closed!("death")
    error = arrived!(upa, patient: patient)
    Urgency::RecordOutcome.call(encounter: error, attrs: { "kind" => "registered_in_error", "reason" => "Paciente lançado por engano" },
                                by: upa_reception!)
    open = arrived!(upa, patient: patient).tap { |x| classified!(x, color: "red", by: nurse, pain_scale: 2, vital_signs: { spo2: 85 }) }
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{shown.attendance_id}/declarations", content: {}, health_unit_id: upa.id
    expect(response).to have_http_status(:created)
    document_id = json_body["id"]

    sign_in_citizen(phone)
    citizen = Citizen.find_by!(phone: phone)
    get "/citizen/history", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    urgency = body["entries"].select { |e| e["kind"] == "urgency" }
    expect(urgency).to eq([ { "id" => "urgency:#{shown.id}", "kind" => "urgency", "occurred_at" => shown.attendance.checked_in_at.iso8601,
                              "unit" => { "name" => "UPA Cajuru" }, "professional_name" => nil,
                              "title" => "Atendimento de urgência — UPA Cajuru",
                              "summary" => "Alta, com orientação para procurar a sua UBS", "status" => nil, "document" => nil,
                              "return_guidance" => "Procure a sua UBS em até 3 dias" } ])
    expect(body["entries"].map { |e| e["kind"] }).not_to include("attendance", "consultation")
    expect(body["entries"].map { |e| e["id"] }).not_to include("urgency:#{death.id}", "urgency:#{error.id}", "urgency:#{open.id}")
    expect(body["entries"].find { |e| e["kind"] == "clinical_document" }.dig("document", "id")).to eq(document_id)
    expect(response.body).not_to include(UrgencyHelpers::COMPLAINT, "Dor intensa", "SpO2", "I10", "Hipertens", "Laranja", "orange",
                                         "Vermelho", "Óbito", "death", "engano", "Reavaliar")

    get "/citizen/documents/#{document_id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
  end
end
