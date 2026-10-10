# spec/requests/clinical_document_cancel_spec.rb
require "rails_helper"

# Contrato §3, spec §6: só a autora, motivo ≥ 10, step-up; 409 já cancelado;
# o pedido pendente sai da fila; "cancelar e emitir outro" é um novo com
# replaces_document_id. Review Focus 4: pedido travado pelo job não trava o
# cancelamento e não fica preso na fila.
RSpec.describe "Cancelamento de documento clínico", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit).tap { |user| user.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def issue! = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor, consultation: consultation).payload[:document]

  it "autora com step-up cancela; motivo curto 422; segunda vez 409; sem step-up 401; outra pessoa 403" do
    document = issue!
    sign_in_as(step_up_enrolled!(doctor))
    json_post "/attendance/documents/#{document.id}/cancel", reason: "Dias errados no atestado"
    expect(json_body).to eq("error" => "mfa_required")
    stepped_up!(doctor)
    json_post "/attendance/documents/#{document.id}/cancel", reason: "curto"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_reason" } ])
    json_post "/attendance/documents/#{document.id}/cancel", reason: "Dias errados no atestado"
    expect(json_body).to include("status" => "cancelled", "cancel_reason" => "Dias errados no atestado")
    expect(DomainEvent.where(name: "clinical_document.cancelled").last.payload).to eq("document_id" => document.id, "kind" => "sick_note")
    json_post "/attendance/documents/#{document.id}/cancel", reason: "Dias errados no atestado"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_cancelled" } ])
    stepped_up!(doctor!(unit))
    json_post "/attendance/documents/#{issue!.id}/cancel", reason: "Dias errados no atestado"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
  end

  it "cancelar e emitir outro; cancelar segue com o interruptor desligado" do
    document = issue!
    stepped_up!(doctor)
    documents_city!(enabled: false)
    json_post "/attendance/documents/#{document.id}/cancel", reason: "Dias errados no atestado"
    expect(response).to have_http_status(:ok)
    documents_city!
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 },
                                                                       replaces_document_id: document.id
    expect(json_body["replaces_document_id"]).to eq(document.id)
  end

  it "pedido pendente sai da fila; travado pelo job, sai depois pelo job (Review Focus 4)" do
    stub_psc!; stub_signer!; signature_city!
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    free = issue!
    held = issue!
    stepped_up!(doctor)
    json_post "/attendance/documents/#{free.id}/cancel", reason: "Emitido para o paciente errado"
    expect(free.signature_request.reload).to have_attributes(status: "returned_to_paper", reason_code: "document_cancelled")

    skipped = SignatureRequest.none
    allow(SignatureRequest).to receive(:lock).and_call_original
    allow(SignatureRequest).to receive(:lock).with("FOR UPDATE SKIP LOCKED").and_return(skipped) # o job segura o pedido
    json_post "/attendance/documents/#{held.id}/cancel", reason: "Emitido para o paciente errado"
    expect(response).to have_http_status(:ok)
    expect(held.signature_request.reload.status).to eq("pending")
    allow(SignatureRequest).to receive(:lock).and_call_original
    expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: held.signature_request.id) }).to eq(:returned_to_paper)
  end
end
