require "rails_helper"

# Consulta descartada (card rotasaude/api#51): é casca sem conteúdo, nunca
# tratada como finalizada. Na leitura clínica comporta-se como inexistente —
# show/print/escrita → o mesmo 404 not_found; fora de toda lista e ficha. O
# documento emitido no rascunho segue legível pela regra do prontuário.
RSpec.describe "Consulta descartada", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:citizen) { verified_citizen!(1) }
  let(:consultation) do
    started_consultation!(unit: unit, doctor: doctor, citizen: citizen).tap do |c|
      Consultations::SaveDraft.call(consultation: c, params: draft_body, by: doctor)
    end
  end

  def discard! = ConsultationDrafts::Discard.call(consultation_id: consultation.id, reason: "rascunho aberto por engano", by: admin)
  def not_found? = response.status == 404 && json_body == { "error" => "not_found" }

  it "show, print, autosave, finalizar e adendo da descartada → 404 not_found, sem trilha" do
    discard!
    sign_in_as(doctor)
    base = "/attendance/consultations/#{consultation.id}"
    get base
    expect(not_found?).to be(true), response.body
    get "#{base}/print"
    expect(not_found?).to be(true), response.body
    patch base, params: { plan: "x" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(not_found?).to be(true), response.body
    json_post "#{base}/finalize", outcome: { outcome: "discharged" }
    expect(not_found?).to be(true), response.body
    json_post "#{base}/addenda", reason: "motivo suficiente", text: "x"
    expect(not_found?).to be(true), response.body
    expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty
  end

  it "documentos, identificação, medicamentos e renovação pela descartada → 404 not_found" do
    discard!
    sign_in_as(doctor)
    base = "/attendance/consultations/#{consultation.id}"
    get "#{base}/documents"
    expect(not_found?).to be(true), response.body
    json_post "#{base}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    expect(not_found?).to be(true), response.body
    expect(ClinicalDocument.count).to eq(0)
    expect(ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor,
                                         consultation: consultation.reload).reason).to eq(:not_found)
    get "#{base}/patient_identification"
    expect(not_found?).to be(true), response.body
    json_post "#{base}/medications", action: "add_external", free_text: "Losartana 50 mg"
    expect(not_found?).to be(true), response.body
    get "#{base}/renewal"
    expect(not_found?).to be(true), response.body
  end

  it "fora do prontuário (ficha do atendimento), de \"minhas consultas\" e da leitura administrativa" do
    discard!
    sign_in_as(doctor)
    get "/attendance/attendances/#{consultation.attendance_id}/record"
    expect(response).to have_http_status(:ok)
    expect(json_body["consultations"]).to eq([])
    get "/attendance/consultations/mine"
    expect(json_body["consultations"]).to eq([])
    expect(Consultation.finalized_list(author_user_id: doctor.id)).to be_empty
    expect(Ledi::ConsultationFicha.generate(consultation.reload)).to eq(:skipped)
  end

  it "o documento emitido no rascunho segue legível pela autora; colega fora de contexto 403" do
    issued = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor,
                                           consultation: consultation)
    document = issued.payload[:document]
    discard!
    sign_in_as(doctor)
    get "/attendance/documents/#{document.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["id"]).to eq(document.id)
    sign_in_as(doctor!(unit))
    get "/attendance/documents/#{document.id}"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
  end

  it "Consultations::Json da descartada: sem bloco de assinatura e sem itens" do
    discard!
    json = Consultations::Json.consultation(consultation.reload)
    expect(json).not_to have_key(:signature)
    expect(json).to include(status: "discarded", evaluated_problems: [], conducts: [], exam_requests: [], subjective: nil, vitals: {})
  end
end
