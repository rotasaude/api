require "rails_helper"

# Desvio 6 (Review Focus 4): pedido pendente de documento cancelado nunca
# fica na fila — sai pelo job, pelo lote ou pela varredura, com
# document_cancelled e sem mudar o modo do documento.
RSpec.describe Signatures::CancelledDocuments do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release!; stub_psc!; stub_signer!; signature_city! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit).tap { |user| user.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def cancelled_digital!
    consultation
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF)) unless SignerCertificate.active.exists?(user_id: doctor.id)
    document = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 1 }, by: doctor,
                                             consultation: consultation).payload[:document]
    document.update!(status: "cancelled", cancel_reason: "Emitido para o paciente errado", cancelled_at: Time.current,
                     cancelled_by_user_id: doctor.id)
    document
  end

  it "o job devolve ao papel sem assinar" do
    document = cancelled_digital!
    outcome = ApplicationRecord.transaction { Signatures::SignPending.call(request_id: document.signature_request.id) }
    expect(outcome).to eq(:returned_to_paper)
    expect(document.signature_request.reload).to have_attributes(status: "returned_to_paper", reason_code: "document_cancelled")
    expect(document.reload.issue_mode).to eq("digital")
    expect(Signature.where(document_type: "ClinicalDocument", document_id: document.id)).to be_empty
  end

  it "o lote tira o cancelado e assina o resto" do
    document = cancelled_digital!
    other = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor,
                                          consultation: consultation).payload[:document]
    token = Signatures::Psc::Token.new(access_token: fake_psc.token_for!(cpf: SignatureHelpers::DOCTOR_CPF), expires_in: 300,
                                       scope: "multi_signature")
    result = Signatures::RunBatch.call(user: doctor, request_ids: [ document.signature_request.id, other.signature_request.id ],
                                       token: token, provider: "vidaas")
    expect(result.payload[:record][:signed]).to eq(1)
    expect(document.signature_request.reload.reason_code).to eq("document_cancelled")
  end

  it "a varredura aposenta o que sobrou" do
    document = cancelled_digital!
    Signatures::SweepJob.new.send(:retire_cancelled_documents, Time.current)
    expect(document.signature_request.reload.status).to eq("returned_to_paper")
  end
end
