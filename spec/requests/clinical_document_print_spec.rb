# spec/requests/clinical_document_print_spec.rb
require "rails_helper"

# Contrato §3 (Desvio 7): impresso do documento — papel na hora; digital
# assinado = o PAdES; digital sem assinatura → 409 awaiting_signature;
# cancelado → 409. Sem cache; nome do arquivo sem dado da pessoa; trilha.
RSpec.describe "Impresso do documento clínico", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def issue! = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 1 }, by: doctor, consultation: consultation).payload[:document]

  it "papel: PDF, no-store, nome neutro, trilha; cancelado 409" do
    document = issue!
    sign_in_as(doctor)
    get "/attendance/documents/#{document.id}/print"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).to start_with("%PDF")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Content-Disposition"]).to include("documento.pdf")
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "author")
    document.update!(status: "cancelled", cancel_reason: "Emitido por engano aqui", cancelled_at: Time.current, cancelled_by_user_id: doctor.id)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "already_cancelled" } ])
  end

  it "recepção imprime a própria declaração (papel)" do
    declaration = ClinicalDocuments::Issue.call(kind: "attendance_declaration", content: {}, by: verifier!,
                                                attendance: consultation.attendance).payload[:document]
    sign_in_as(verifier!)
    get "/attendance/documents/#{declaration.id}/print"
    expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
  end

  # Sem a Task 18 o 19b ainda não assina documento clínico: aqui a fiação do
  # impresso (pendente → 409; com assinatura gravada → os bytes dela, sem
  # gerar outro PDF; cancelado ganha do modo). O caminho real é o exemplo abaixo.
  it "digital: sem assinatura 409 awaiting_signature; com a gravada, os bytes do PAdES; cancelado 409" do
    document = raw_document!(consultation: consultation, issue_mode: "digital")
    sign_in_as(doctor)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "awaiting_signature" } ])

    signed = instance_double(Signature, signed_pdf_bytes: "%PDF-1.7 pades".b)
    allow_any_instance_of(ClinicalDocument).to receive(:signed_signature).and_return(signed)
    expect(ClinicalDocuments::Pdf).not_to receive(:call)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, response.media_type, response.body.b ]).to eq([ 200, "application/pdf", "%PDF-1.7 pades".b ])
    expect(response.headers["Cache-Control"]).to include("no-store")

    document.update!(status: "cancelled", cancel_reason: "Emitido por engano aqui", cancelled_at: Time.current,
                     cancelled_by_user_id: doctor.id)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "already_cancelled" } ])
  end

  it "digital pendente → 409 awaiting_signature; assinado → o PDF assinado",
     skip: "depende da Task 18 (Signatures::Documents ainda não prepara ClinicalDocument); a Task 18 tira o skip" do
    stub_psc!
    stub_signer!
    signature_city!
    doctor.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    document = issue!
    sign_in_as(doctor)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "awaiting_signature" } ])
    signature = sign_document!(document, author: doctor)
    get "/attendance/documents/#{document.id}/print"
    expect(response.body.b).to eq(signature.signed_pdf_bytes.b)
  end
end
