require "rails_helper"
require "prawn"

# Contrato §9 contra o SERVIÇO real (compose): AD-RB em CAdES destacado e em
# PAdES, com a assinatura RAW feita pela chave da folha da AC de teste (como o
# PSC faria). A AC é a do DevPki do signer (volume signer-dev-pki; Task 2).
RSpec.describe "Serviço signer (real)", :signer do
  let(:client) { Signatures::Signer.client }
  let(:leaf) { test_pki.leaf_for(SignatureHelpers::DOCTOR_CPF) }

  def raw(prepared) = leaf.key.sign_raw("SHA256", prepared.digest)

  it "CAdES destacado AD-RB: prepara, monta e verifica; JSON adulterado não verifica" do
    document = '{"schema":"rotasaude.consultation.v1","texto":"Ação ≥ 1"}'
    prepared = client.prepare(kind: "cades", document: document, certificate_der: leaf.der)
    assembled = client.assemble(kind: "cades", state: prepared.state, signature_value: raw(prepared))
    result = client.verify(kind: "cades", signature: assembled.signature, document: document)
    expect(result.status).to eq("valid")
    expect(result.signer_cpf).to eq(SignatureHelpers::DOCTOR_CPF)
    expect(result.policy_oid).to start_with("2.16.76.1.7.1")
    expect(assembled.validation_material.bytesize).to be > 0
    expect(client.verify(kind: "cades", signature: assembled.signature, document: document.sub("1", "2")).status)
      .not_to eq("valid")
  end

  it "PAdES AD-RB sobre um PDF do Prawn" do
    pdf = Prawn::Document.new.tap { |d| d.text "Registro de consulta" }.render
    prepared = client.prepare(kind: "pades", document: pdf, certificate_der: leaf.der)
    assembled = client.assemble(kind: "pades", state: prepared.state, signature_value: raw(prepared))
    expect(assembled.signature).to start_with("%PDF")
    expect(client.verify(kind: "pades", signature: assembled.signature).status).to eq("valid")
  end

  it "valor de assinatura que não confere é recusado; o certificado de teste confere; health responde" do
    prepared = client.prepare(kind: "cades", document: "{}", certificate_der: leaf.der)
    expect { client.assemble(kind: "cades", state: prepared.state, signature_value: "x" * 256) }
      .to raise_error(Signatures::Signer::Rejected)
    check = client.check_certificate(certificate_der: leaf.der)
    expect([ check.status, check.signer_cpf ]).to eq([ "valid", SignatureHelpers::DOCTOR_CPF ])
    expect(client.health[:version]).to be_present
  end

  it "lixo no lugar do certificado é recusa (400/422), sem vazar o corpo" do
    expect { client.prepare(kind: "cades", document: "{}", certificate_der: "lixo") }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to match(/\Ainvalid_/) }
  end

  it "estado de PDF acima de 32 MiB é recusado como invalid_request (400), não transitório" do
    big = "%PDF-1.4\n".b + ("0" * (33 * 1024 * 1024)).b
    expect { client.prepare(kind: "pades", document: big, certificate_der: leaf.der) }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to eq("invalid_request") }
  end
end
