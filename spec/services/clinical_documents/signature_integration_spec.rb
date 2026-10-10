require "rails_helper"

# ADR 0033 + ADR 0032: o documento clínico digital é assinado como a consulta
# (JSON canônico em CAdES, PDF com rodapé NGS2 em PAdES), pelo job ou pelo
# lote; a volta ao papel passa o documento a paper; o impresso da consulta do
# 19a não muda por causa de documentos.
RSpec.describe "Assinatura de documento clínico" do
  before do
    documents_city!; ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    stub_psc!
    stub_signer!
    signature_city!
  end

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit).tap { |user| user.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def issue! = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor, consultation: consultation).payload[:document]

  it "assina ponta a ponta com o PSC falso: assinatura do documento, bloco digital, fila com issued_at" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    document = issue!
    request = document.signature_request
    expect(Signatures::Json.requests([ request ]).sole).to include(document_type: "clinical_document", document_id: document.id,
                                                                  finalized_at: document.issued_at.iso8601)
    signature = sign_document!(document, author: doctor)
    expect(signature).to have_attributes(document_type: "ClinicalDocument", document_id: document.id)
    expect(JSON.parse(signature.canonical_json)).to include("schema" => "rotasaude.clinical_document.v1")
    expect(signature.canonical_sha256).to eq(Signatures::Canonical.clinical_document(document).sha256)
    expect(ClinicalDocuments::Json.document(document.reload)[:signature]).to include(mode: "digital", simulated: false)
    expect { document.update!(issue_mode: "paper") }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
  end

  it "volta ao papel passa o documento a paper; cancelado sai sem mudar o modo" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    first = issue!
    Signatures::ReturnToPaper.call(request_id: first.signature_request.id, by: doctor, reason: "Paciente pediu o papel agora")
    expect(first.reload.issue_mode).to eq("paper")
    second = issue!
    Signatures::ToPaper.call(second.signature_request.lock!, reason_code: "document_cancelled")
    expect(second.reload.issue_mode).to eq("digital")
  end

  it "o impresso da consulta do 19a ignora pedidos de documentos" do
    consultation # finalizada antes do certificado: a consulta não tem pedido
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    issue!
    expect(Signatures::PrintReport.for(consultation)).to be_nil
  end

  # A cadeia do ADR 0032 é da consulta e dos adendos: a falha de um documento
  # clínico não segura a consulta nem os outros documentos do mesmo lote.
  it "no mesmo lote, o documento que falha não bloqueia a consulta nem o outro documento" do
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    broken = issue!
    sound = issue!
    requests = [ consultation.then { SignatureRequest.find_by!(document_type: "Consultation", document_id: consultation.id) },
                 broken.signature_request, sound.signature_request ]
    allow(ClinicalDocuments::Pdf).to receive(:call).and_call_original
    allow(ClinicalDocuments::Pdf).to receive(:call).with(having_attributes(id: broken.id), footer: anything)
                                                   .and_raise(ClinicalDocuments::Pdf::NotPrintable, "cancelled")
    outcome = ApplicationRecord.transaction do
      Signatures::Signing.call(requests: requests.map(&:lock!), access_token: fake_psc.token_for!(cpf: SignatureHelpers::DOCTOR_CPF),
                               certificate: certificate)
    end
    expect(outcome.signed.map(&:document_id)).to contain_exactly(consultation.id, sound.id)
    expect(outcome.failed.map { |request, reason| [ request.document_id, reason ] }).to eq([ [ broken.id, "verification_failed" ] ])
    expect(outcome.final).to eq([ broken.signature_request.id ])
  end
end
