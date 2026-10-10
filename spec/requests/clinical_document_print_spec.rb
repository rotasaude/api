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

  # A fiação do impresso (pendente → 409; com assinatura gravada e válida → os
  # bytes dela, sem gerar outro PDF; cancelado ganha do modo). O caminho real,
  # assinado pelo 19b, é o contexto abaixo.
  it "digital: sem assinatura 409 awaiting_signature; com a gravada, os bytes do PAdES; cancelado 409" do
    document = raw_document!(consultation: consultation, issue_mode: "digital")
    sign_in_as(doctor)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "awaiting_signature" } ])

    signed = instance_double(Signature, signed_pdf_bytes: "%PDF-1.7 pades".b, last_verification: "valid")
    allow_any_instance_of(ClinicalDocument).to receive(:signed_signature).and_return(signed)
    allow(Signatures::Verify).to receive(:call).with(signed).and_return(signed)
    expect(ClinicalDocuments::Pdf).not_to receive(:call)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, response.media_type, response.body.b ]).to eq([ 200, "application/pdf", "%PDF-1.7 pades".b ])
    expect(response.headers["Cache-Control"]).to include("no-store")

    document.update!(status: "cancelled", cancel_reason: "Emitido por engano aqui", cancelled_at: Time.current,
                     cancelled_by_user_id: doctor.id)
    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "already_cancelled" } ])
  end

  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  # Ponta a ponta com o PSC simulado do 19b: o impresso do documento assinado
  # segue a política do impresso da consulta (Signatures::PrintReport.signed_pdf
  # revalida antes de devolver o PAdES; fora de `valid`, o PDF gerado com o
  # estado da assinatura e espaço à mão).
  context "assinado de verdade (PSC simulado)" do
    let(:signer) { stub_signer! }

    before do
      stub_psc_mock!
      signer
      doctor.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
      linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(SignatureHelpers::DOCTOR_CPF))
    end

    it "digital pendente → 409 awaiting_signature; assinado → os bytes do PAdES, com o aviso de simulada" do
      document = issue!
      expect(document.signed_signature).to be_nil # pending
      sign_in_as(doctor)
      get "/attendance/documents/#{document.id}/print"
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 409, { "error" => "awaiting_signature" } ])
      signature = sign_document!(document, author: doctor, provider: "simulated")
      expect(document.signed_signature).to eq(signature)
      get "/attendance/documents/#{document.id}/print"
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
      expect(response.body.b).to eq(signature.signed_pdf_bytes.b)
      bytes = response.body.b
      # Por trecho de texto (runs): o layout do PDF::Reader embaralha as linhas
      # de 7 pt do rodapé quando ficam próximas.
      runs = PDF::Reader.new(StringIO.new(bytes[0...bytes.rindex(FakeSigner::MARKER)])).pages.map { |page| page.runs.map(&:text).join(" ") }
      expect(runs).to all(include("Assinatura simulada — sem validade jurídica"))
      expect(signer.calls.count(:verify)).to be >= 2 # revalidou ao imprimir (CAdES e PAdES)
    end

    it "assinatura que não revalida como válida → o PDF gerado com o estado e espaço à mão, não o PAdES" do
      document = issue!
      signature = sign_document!(document, author: doctor, provider: "simulated")
      signer.revoked_serials << signature.signer_certificate.serial_number
      sign_in_as(doctor)
      get "/attendance/documents/#{document.id}/print"
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
      expect(response.body.b).not_to eq(signature.signed_pdf_bytes.b)
      text = text_of(response.body)
      expect(text).to include("Via digital: assinada digitalmente (simulada — sem validade jurídica) por", "validação inválida")
      expect(signature.reload.last_verification).to eq("invalid")
    end

    # Uma linha de assinatura ao lado de pedido não signed (estado que o fluxo
    # não produz): o filtro por status é o que decide, não a existência da linha.
    it "signed_signature só devolve a assinatura de pedido signed (pending/returned_to_paper → nil)" do
      certificate = SignerCertificate.active.find_by!(user_id: doctor.id)
      pending = issue!
      signature_row!(pending.signature_request, certificate: certificate)
      expect(pending.signature_request.status).to eq("pending")
      expect(pending.signed_signature).to be_nil

      returned = issue!
      Signatures::ToPaper.call(returned.signature_request.lock!, reason_code: "user_request")
      signature_row!(returned.signature_request, certificate: certificate)
      expect(returned.signed_signature).to be_nil

      signed = issue!
      signature = sign_document!(signed, author: doctor, provider: "simulated")
      expect(signed.signed_signature).to eq(signature)
    end
  end
end
