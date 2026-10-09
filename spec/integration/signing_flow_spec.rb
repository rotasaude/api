# spec/integration/signing_flow_spec.rb
require "rails_helper"

# O fluxo inteiro contra o SIGNER REAL (compose) e o PSC falso: consulta
# finalizada → JSON canônico + PDF → prepare → RAW no PSC → assemble → verify →
# gravado; e o que foi gravado verifica de novo no signer.
RSpec.describe "Assinatura de ponta a ponta (signer real)", :signer do
  before do
    Current.city = signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
    stub_psc!
  end
  after { Current.reset }

  it "assina a consulta e o adendo; CAdES e PAdES verificam no signer" do
    unit = create_unit
    doctor = signer_doctor!(unit)
    cpf = SignatureHelpers::DOCTOR_CPF
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: cpf))
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    addendum = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame adicional pedido",
                                               text: "Texto do adendo").payload[:addendum]
    [ consultation, addendum ].each do |document|
      request = signature_request!(document, author: doctor)
      expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: request.id) }).to eq(:signed)
      signature = request.reload.signature
      client = Signatures::Signer.client
      expect(client.verify(kind: "cades", signature: signature.cades_bytes, document: signature.canonical_json).status).to eq("valid")
      expect(client.verify(kind: "pades", signature: signature.signed_pdf_bytes).status).to eq("valid")
    end
  end
end
