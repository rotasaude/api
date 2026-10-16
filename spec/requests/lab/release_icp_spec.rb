require "rails_helper"

# Spec §5.7 (ICP pelo 19b): o laudo nasce pending_signature, aparece nas
# pendências do liberador, o 21a só recebe depois da assinatura (PDF
# assinado); voltar ao papel não se aplica; interruptor desligado retira.
# Rulings da Task 18: falha definitiva do laudo na assinatura vira motivo
# terminal (document_cancelled, nunca verification_failed); o liberador só do
# laboratório só alcança pedidos de laudo no 19b.
RSpec.describe "Laboratório — liberação com ICP", type: :request do
  before do
    lab_city!
    stub_psc_mock!(City.find(Current.city.id))
    stub_signer!
  end

  let(:provider) { lab_provider! }
  let(:doctor) do
    lab_releaser!(provider, council: "CRM", lead: true).tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) }
  end
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }
  let(:item) { type!(req.items.first, { glicose: "98" }) }

  def certificate! = linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(doctor.professional.cpf))

  def pending_report!
    certificate!
    Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "icp", totp: nil, by: doctor).payload.fetch(:report)
  end

  it "pendente → assinado: laudo liberado com o PDF assinado e resultado no 21a" do
    sign_in_as(doctor)
    json_post "/lab/requisitions/#{req.id}/release", item_ids: [ item.id ], signature: "icp"
    expect(json_body["error"]).to eq("no_active_certificate")
    certificate!
    json_post "/lab/requisitions/#{req.id}/release", item_ids: [ item.id ], signature: "icp"
    expect(json_body).to include("status" => "pending_signature", "pdf_url" => nil, "short_code" => nil)
    report = LabReport.find(json_body["id"])
    expect(item.exam_order.reload.result).to be_nil
    get "/signature/requests"
    expect(json_body["items"].sole).to include("document_type" => "lab_report", "consultation_id" => nil,
                                               "patient_display_name" => req.patient.display_name,
                                               "finalized_at" => report.created_at.iso8601)
    json_post "/signature/requests/#{json_body['items'].sole['id']}/return_to_paper", reason: "Certificado com problema hoje"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "not_applicable" ])
    json_post "/lab/requisitions/#{req.id}/release", item_ids: [ item.id ], signature: "icp"
    expect(json_body["error"]).to eq("invalid_transition")

    signature = sign_document!(report, author: doctor, provider: "simulated")
    expect(signature.canonical_sha256).to eq(report.content_sha256)
    expect(report.reload).to have_attributes(status: "released", pdf_sha256: Digest::SHA256.hexdigest(signature.signed_pdf_bytes))
    result = item.exam_order.reload.result
    expect(result.source).to eq("lab")
    expect(result.pdf_file.bytes).to eq(signature.signed_pdf_bytes)
    expect(DomainEvent.where(name: "signature.signed").sole.payload).to include("document_type" => "lab_report")
  end

  it "interruptor desligado antes de assinar: o laudo sai (withdrawn) e o item volta à fila" do
    report = pending_report!
    Platform::Features.set!(city: City.find(Current.city.id), key: "digital_signature", enabled: false, maintainer: ledi_maintainer!)
    ApplicationRecord.transaction { Signatures::SignPending.call(request_id: report.signature_request.id) }
    expect(report.reload).to have_attributes(status: "withdrawn", released_at: nil, pdf_file_id: nil, pdf_sha256: nil)
    expect(DomainEvent.where(name: "lab_report.withdrawn").count).to eq(1)
    sign_in_as(doctor)
    get "/lab/releases", params: { provider_id: provider.id }
    expect(json_body["requisitions"].map { |r| r["id"] }).to eq([ req.id ])
  end

  it "laudo só sai do pedido pelo sistema: outro motivo de volta ao papel é recusado" do
    request = pending_report!.signature_request
    expect { Signatures::ToPaper.call(request, reason_code: "user_request", note: "Pedido do autor aqui") }
      .to raise_error(ArgumentError)
  end

  it "falha definitiva ao finalizar: nada gravado, pedido pendente com motivo terminal (document_cancelled)" do
    report = pending_report!
    allow(Lab::FinalizeReport).to receive(:call).and_return(Result.fail(:invalid_transition))
    expect { sign_document!(report, author: doctor, provider: "simulated") }.to raise_error(/document_cancelled/)
    request = report.signature_request
    expect(request).to have_attributes(status: "pending", reason_code: "document_cancelled", attempts: 0)
    expect(SignatureRequest::TRANSIENT_REASONS).not_to include("document_cancelled")
    expect(Signature.where(document_type: "LabReport").count).to eq(0)
    expect(report.reload.status).to eq("pending_signature")
    expect(DomainEvent.where(name: "signature.signed").count).to eq(0)
  end

  it "liberador só do laboratório: o 19b mostra e assina só pedidos de laudo" do
    report = pending_report!
    other = signature_request!(author: doctor) # pedido de consulta do mesmo usuário (ex.: papel antigo)
    sign_in_as(doctor)
    get "/signature/requests"
    expect(json_body["items"].map { |i| i["id"] }).to eq([ report.signature_request.id ])
    json_post "/signature/requests/#{other.id}/return_to_paper", reason: "Certificado com problema hoje"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_post "/signature/batches", request_ids: [ other.id ]
    expect([ response.status, json_body["error"] ]).to eq([ 409, "nothing_pending" ])
    expect(other.reload.status).to eq("pending")
    rows = SignatureRequest.signable_by(doctor).where(id: [ other.id, report.signature_request.id ]).pluck(:id)
    expect(rows).to eq([ report.signature_request.id ])
  end

  it "a assinatura do laudo não se lê pelas rotas da consulta (o laudo se lê por /lab)" do
    report = pending_report!
    signature = sign_document!(report, author: doctor, provider: "simulated")
    stepped_up!(lab_admin!)
    get "/signature/signatures/#{signature.id}"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
  end
end
