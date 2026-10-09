# spec/services/signatures/certificate_info_spec.rb
require "rails_helper"
require_relative "../../../lib/fake_psc/pki"

# ADR 0032 (spec §5; NGS2.01.02/02.02): do certificado ICP-Brasil o api lê o
# CPF (otherName 2.16.76.1.3.1), o nome (CN "NOME:CPF"), o serial, o emissor, a
# validade e o uso de chave.
RSpec.describe Signatures::CertificateInfo do
  let(:pki) { FakePsc::Pki.load(FakePsc::Pki::FIXTURES) }

  it "lê CPF, nome, serial, emissor e validade do certificado de teste" do
    leaf = pki.issue(cpf: "52998224725", name: "MARIA DA SILVA")
    info = described_class.parse(leaf.der)
    expect(info.cpf).to eq("52998224725")
    expect(info.holder_name).to eq("MARIA DA SILVA")
    expect(info.serial_number).to eq(leaf.serial_hex)
    expect(info.issuer_name).to eq("AC Rota Saude Teste v1")
    expect(info.issuer_dn).to include("CN=AC Rota Saude Teste v1")
    expect(info.signing_usage?).to be(true)
    expect(info.expired?).to be(false)
  end

  it "nome com acento; certificado vencido; uso de chave sem não repúdio" do
    leaf = pki.issue(cpf: "11144477735", name: "JOÃO CONCEIÇÃO", not_before: Time.now - 7200, not_after: Time.now - 60,
                     key_usage: "digitalSignature")
    info = described_class.parse(leaf.der)
    expect(info.holder_name).to eq("JOÃO CONCEIÇÃO")
    expect(info.expired?).to be(true)
    expect(info.signing_usage?).to be(false)
  end

  it "sem o otherName ICP não há CPF; bytes que não são certificado levantam Invalid sem eco" do
    expect(described_class.new(pki.ca).cpf).to be_nil
    expect { described_class.parse("lixo-52998224725") }
      .to raise_error(described_class::Invalid) { |error| expect(error.message).not_to include("5299") }
    expect(described_class.parse(pki.issue(cpf: "52998224725", name: "X").der).inspect).not_to include("52998224725")
  end

  it "a cadeia de teste fecha: folha → AC → raiz" do
    leaf = pki.leaf_for("52998224725")
    expect(pki.leaf_for("52998224725")).to equal(leaf) # memorizado por CPF
    store = OpenSSL::X509::Store.new
    store.add_cert(pki.root)
    expect(store.verify(leaf.certificate, [ pki.ca ])).to be(true)
  end
end
