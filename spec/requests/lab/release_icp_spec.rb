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

  # B56: o laudo sai (withdrawn), os itens voltam à fila e o pedido se
  # resolve com o motivo terminal document_cancelled.
  def expect_withdrawn!(report)
    request = report.signature_request
    expect(request).to have_attributes(status: "returned_to_paper", reason_code: "document_cancelled", attempts: 0)
    expect(request.resolved_at).to be_present
    expect(SignatureRequest::TRANSIENT_REASONS).not_to include("document_cancelled")
    expect(Signature.where(document_type: "LabReport").count).to eq(0)
    expect(report.reload).to have_attributes(status: "withdrawn", released_at: nil, pdf_file_id: nil, pdf_sha256: nil)
    expect(DomainEvent.where(name: "lab_report.withdrawn").sole.payload).to eq("lab_report_id" => report.id)
    expect(DomainEvent.where(name: "signature.signed").count).to eq(0)
    expect(Lab::Frozen.item?([ item.id ])).to be(false)
    expect(item.exam_order.reload.result).to be_nil
    sign_in_as(lab_releaser!(provider))
    get "/lab/releases", params: { provider_id: provider.id }
    expect(json_body["requisitions"].map { |r| r["id"] }).to eq([ req.id ])
  end

  def open_session!
    signature_session!(doctor, certificate: SignerCertificate.active.find_by!(user_id: doctor.id),
                               token: fake_psc("simulated").token_for!(cpf: doctor.professional.cpf))
  end

  def sign_in_background!(report)
    Signatures::SignJob.perform_now(city_slug: Current.city.slug, request_id: report.signature_request.id)
  end

  it "falha definitiva ao finalizar (B56): nada gravado, laudo withdrawn, pedido document_cancelled" do
    report = pending_report!
    allow(Lab::FinalizeReport).to receive(:call).and_return(Result.fail(:invalid_transition))
    expect { sign_document!(report, author: doctor, provider: "simulated") }.to raise_error(/returned_to_paper document_cancelled/)
    expect_withdrawn!(report)
  end

  it "o lote (RunBatch) com falha definitiva: o pedido sai resolvido e aparece em failed, sem Park" do
    report = pending_report!
    open_session!
    allow(Lab::FinalizeReport).to receive(:call).and_return(Result.fail(:invalid_transition))
    token = Struct.new(:access_token).new(SignatureSession.usable_for(doctor.id).access_token)
    result = Signatures::RunBatch.call(user: doctor, request_ids: [ report.signature_request.id ], token: token, provider: "simulated")
    expect(result.payload[:record]).to eq(signed: 0, failed: [ { request_id: report.signature_request.id, reason_code: "document_cancelled" } ])
    expect(DomainEvent.where(name: "signature.failed").count).to eq(0)
    expect_withdrawn!(report)
  end

  it "I1: encerrar o liberador retira os laudos ICP pendentes dele naquele laboratório" do
    report = pending_report!
    link = LabReleaser.active.find_by!(user_id: doctor.id, exam_provider_id: provider.id)
    other_lab = lab_provider!
    LabReleaser.create!(user: doctor, exam_provider: other_lab, technical_lead: true, technical_deputy: false)
    other_req = received_requisition!(provider: other_lab, exams: [ lab_exam!(provider: other_lab) ])
    other_item = type!(other_req.items.first, { glicose: "90" })
    elsewhere = Lab::Release.call(requisition: other_req, item_ids: [ other_item.id ], signature: "icp", totp: nil, by: doctor).payload.fetch(:report)

    expect(Lab::AssignReleaser.end!(releaser: link, by: lab_admin!)).to be_ok
    expect_withdrawn!(report)
    expect(elsewhere.reload.status).to eq("pending_signature")
    expect(elsewhere.signature_request.status).to eq("pending")
  end

  it "I1: liberador desligado do laboratório (sem o end!) — a assinatura em segundo plano cai no B56" do
    report = pending_report!
    open_session!
    LabReleaser.active.find_by!(user_id: doctor.id, exam_provider_id: provider.id).update!(ended_at: Time.current)
    sign_in_background!(report)
    expect_withdrawn!(report)
  end

  it "I1: sem o papel lab_releaser na cidade — a assinatura em segundo plano cai no B56" do
    report = pending_report!
    open_session!
    doctor.memberships.active.where(role: "lab_releaser").update_all(revoked_at: Time.current)
    sign_in_background!(report)
    expect_withdrawn!(report)
  end

  it "I1-b: sessão aberta de liberador só do laboratório nunca assina pedido de consulta em segundo plano" do
    pending_report!
    open_session!
    other = signature_request!(author: doctor) # pedido de consulta do mesmo usuário (ex.: papel antigo)
    Signatures::SignJob.perform_now(city_slug: Current.city.slug, request_id: other.id)
    expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: other.id) }).to eq(:skipped)
    expect(other.reload).to have_attributes(status: "pending", reason_code: nil, attempts: 0)
    expect(Signature.count).to eq(0)
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
