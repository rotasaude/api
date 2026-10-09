require "rails_helper"

# ADR 0032 (spec §5): corrida de dois vínculos do mesmo usuário — o índice
# parcial (um active por usuário) recusa o segundo; vale o que ficou gravado.
RSpec.describe Signatures::AcceptCertificate do
  before { Current.city = signature_city! }
  after { Current.reset }

  let(:doctor) { signer_doctor!(create_unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }

  def entry(leaf) = Signatures::Psc::CertificateEntry.new(certificate_alias: cpf, der: leaf.der)

  it "outro vínculo gravou o active entre a leitura e o create!: devolve o vencedor, sem troca nem evento" do
    winner = linked_certificate!(doctor, leaf: test_pki.issue(cpf: cpf, name: "VENCEDOR"))
    calls = 0
    allow(SignerCertificate).to receive(:active).and_wrap_original do |original|
      calls += 1
      calls == 1 ? SignerCertificate.none : original.call # a leitura com lock não viu o concorrente
    end

    result = described_class.call(user: doctor, provider: "vidaas", entries: [ entry(test_pki.issue(cpf: cpf, name: "PERDEDOR")) ],
                                  signer: FakeSigner.new)

    expect(result).to be_ok
    expect(result.payload).to eq(certificate: winner, changed: false)
    expect(SignerCertificate.where(user_id: doctor.id).pluck(:id, :status)).to eq([ [ winner.id, "active" ] ])
    expect(DomainEvent.where(name: "signature.certificate_linked")).to be_empty
  end
end
