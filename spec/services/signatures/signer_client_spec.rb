require "rails_helper"

# Contrato §9 (api/worker → signer): Bearer, JSON em base64, corpo nunca
# logado; 400/422 = recusa com código, 401/5xx/rede = indisponível.
RSpec.describe Signatures::Signer::Client do
  let(:base) { "http://signer.test:8090" }
  let(:client) { described_class.new(url: base, token: "SEGREDO-DO-SIGNER") }
  let(:auth) { { "Authorization" => "Bearer SEGREDO-DO-SIGNER" } }

  def reply(body, code = 200) = { status: code, headers: { "Content-Type" => "application/json" }, body: body.to_json }

  it "prepare e assemble: base64 nas duas pontas" do
    stub_request(:post, "#{base}/prepare").with(headers: auth, body: { kind: "cades", document_base64: Base64.strict_encode64("doc"),
                                                                       certificate_der_base64: Base64.strict_encode64("der"), policy: "AD-RB" })
      .to_return(reply({ to_be_signed_sha256_base64: Base64.strict_encode64("h" * 32), prepared_state: "ESTADO" }))
    prepared = client.prepare(kind: "cades", document: "doc", certificate_der: "der")
    expect(prepared).to have_attributes(digest: "h" * 32, state: "ESTADO")

    stub_request(:post, "#{base}/assemble").with(body: { kind: "cades", prepared_state: "ESTADO", signature_value_base64: Base64.strict_encode64("RAW") })
      .to_return(reply({ signature_base64: Base64.strict_encode64("P7S"), validation_material_base64: Base64.strict_encode64("LCR") }))
    expect(client.assemble(kind: "cades", state: "ESTADO", signature_value: "RAW"))
      .to have_attributes(signature: "P7S", validation_material: "LCR")
  end

  it "verify, check do certificado e health (o /health também leva o token)" do
    stub_request(:post, "#{base}/verify").with(body: hash_including("kind" => "pades", "signature_base64" => Base64.strict_encode64("PDF")))
      .to_return(reply({ status: "valid", signer_cpf: "52998224725", signer_name: "MARIA", policy_oid: "2.16.76.1.7.1.11.1.1",
                         signed_at: "2026-10-08T12:00:00Z", reasons: [] }))
    result = client.verify(kind: "pades", signature: "PDF")
    expect(result).to have_attributes(status: "valid", signer_cpf: "52998224725", policy_oid: "2.16.76.1.7.1.11.1.1",
                                      signed_at: Time.utc(2026, 10, 8, 12))
    expect(result.inspect).not_to include("52998224725", "MARIA")
    expect(result.pretty_inspect).not_to include("52998224725", "MARIA")

    stub_request(:post, "#{base}/certificates/check").with(headers: auth, body: { certificate_der_base64: Base64.strict_encode64("der") })
      .to_return(reply({ status: "invalid", signer_cpf: "52998224725", not_after: "2027-10-08T12:00:00Z", reasons: [ "certificate_revoked" ] }))
    check = client.check_certificate(certificate_der: "der")
    expect(check).to have_attributes(status: "invalid", signer_cpf: "52998224725", not_after: Time.utc(2027, 10, 8, 12),
                                     reasons: [ "certificate_revoked" ])
    expect(check.inspect).not_to include("52998224725")
    expect(check.pretty_inspect).not_to include("52998224725")
    stub_request(:get, "#{base}/health").with(headers: auth).to_return(reply({ version: "1.0.0", crl_updated_at: "2026-10-08T03:00:00Z" }))
    expect(client.health).to eq(version: "1.0.0", crl_updated_at: Time.utc(2026, 10, 8, 3))
  end

  it "prepare e assemble não vazam bytes nem estado no inspect/pretty_print" do
    prepared = Signatures::Signer::Prepared.new(digest: "SEGREDO-BYTES", state: "SEGREDO-ESTADO")
    assembled = Signatures::Signer::Assembled.new(signature: "SEGREDO-ASSINATURA", validation_material: "SEGREDO-LCR")
    [ prepared, assembled ].each do |value|
      expect([ value.inspect, value.pretty_inspect, value.to_s, "#{value}" ].join).not_to include("SEGREDO")
    end
    verification = Signatures::Signer::Verification.new(status: "valid", signer_cpf: "52998224725", signer_name: "MARIA",
                                                        policy_oid: "1", signed_at: nil, reasons: [])
    check = Signatures::Signer::CertificateCheck.new(status: "valid", signer_cpf: "52998224725", not_after: nil, reasons: [])
    [ verification, check ].each do |value|
      expect([ value.to_s, "#{value}", value.pretty_inspect ].join).not_to include("52998224725", "MARIA")
    end
    expect(client.pretty_inspect).not_to include("SEGREDO")
  end

  it "422 é recusa com código; 401, 500, rede e URL ausente são indisponibilidade; nada vaza" do
    stub_request(:post, "#{base}/assemble").to_return(reply({ error: "invalid_signature_value" }, 422))
    expect { client.assemble(kind: "cades", state: "E", signature_value: "R") }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to eq("invalid_signature_value") }
    [ 401, 500 ].each do |status|
      stub_request(:get, "#{base}/health").to_return(reply({ error: "x" }, status))
      expect { client.health }.to raise_error(Signatures::Signer::Unavailable) { |e| expect(e.message).not_to include("SEGREDO") }
    end
    stub_request(:get, "#{base}/health").to_raise(Errno::ECONNREFUSED)
    expect { client.health }.to raise_error(Signatures::Signer::Unavailable)
    stub_request(:get, "#{base}/health").to_timeout
    expect { client.health }.to raise_error(Signatures::Signer::Unavailable)
    expect { described_class.new(url: nil, token: nil).health }.to raise_error(Signatures::Signer::Unavailable)
    expect(client.inspect).not_to include("SEGREDO")
  end

  it "/prepare: 500 (LCR fora do ar) é transitório; 422 invalid_certificate e 400 invalid_request são recusas" do
    stub_request(:post, "#{base}/prepare").to_return(reply({ error: "internal" }, 500))
    expect { client.prepare(kind: "pades", document: "d", certificate_der: "c") }.to raise_error(Signatures::Signer::Unavailable)

    stub_request(:post, "#{base}/prepare").to_return(reply({ error: "invalid_certificate" }, 422))
    expect { client.prepare(kind: "pades", document: "d", certificate_der: "c") }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to eq("invalid_certificate") }

    stub_request(:post, "#{base}/prepare").to_return(reply({ error: "invalid_request" }, 400))
    expect { client.prepare(kind: "pades", document: "d", certificate_der: "c") }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to eq("invalid_request") }

    stub_request(:post, "#{base}/prepare").to_return(status: 400, body: "<html>SEGREDO CPF 52998224725</html>")
    expect { client.prepare(kind: "pades", document: "d", certificate_der: "c") }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect([ e.code, e.message ].join).not_to include("SEGREDO", "52998224725") }
  end

  it "status fora do contrato no verify é indisponibilidade (nunca 'valid' por engano)" do
    stub_request(:post, "#{base}/verify").to_return(reply({ status: "ok" }))
    expect { client.verify(kind: "cades", signature: "S", document: "D") }.to raise_error(Signatures::Signer::Unavailable)
  end
end

RSpec.describe FakeSigner do
  let(:fake) { described_class.new }
  let(:leaf) { test_pki.leaf_for(SignatureHelpers::DOCTOR_CPF) }
  let(:serial) { Signatures::CertificateInfo.parse(leaf.der).serial_number }

  it "assinatura RAW malformada é recusada, não estoura" do
    prepared = fake.prepare(kind: "cades", document: "{}", certificate_der: leaf.der)
    expect { fake.assemble(kind: "cades", state: prepared.state, signature_value: "x") }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to eq("invalid_signature_value") }
  end

  it "mesma superfície do cliente real" do
    %i[prepare assemble verify check_certificate health].each do |name|
      expect(fake.method(name).parameters).to eq(Signatures::Signer::Client.instance_method(name).parameters)
    end
  end

  it "assina de verdade e recusa documento adulterado" do
    prepared = fake.prepare(kind: "cades", document: "{}", certificate_der: leaf.der)
    assembled = fake.assemble(kind: "cades", state: prepared.state, signature_value: leaf.key.sign_raw("SHA256", prepared.digest))
    expect(fake.verify(kind: "cades", signature: assembled.signature, document: "{}").status).to eq("valid")
    expect(fake.verify(kind: "cades", signature: assembled.signature, document: "{ }").status).to eq("invalid")
  end

  it "prepare recusa certificado revogado ou fora da cadeia com invalid_certificate (como o real)" do
    fake.revoked_serials << serial
    expect { fake.prepare(kind: "cades", document: "{}", certificate_der: leaf.der) }
      .to raise_error(Signatures::Signer::Rejected) { |e| expect(e.code).to eq("invalid_certificate") }
    fake.revoked_serials.clear
    fake.untrusted_serials << serial
    expect { fake.prepare(kind: "cades", document: "{}", certificate_der: leaf.der) }
      .to raise_error(Signatures::Signer::Rejected, /invalid_certificate/)
    expect { fake.prepare(kind: "cades", document: "{}", certificate_der: "lixo") }
      .to raise_error(Signatures::Signer::Rejected, /invalid_certificate/)
  end

  it "LCR indisponível no prepare é indisponibilidade; fora do ar também" do
    fake.revocation_unavailable = true
    expect { fake.prepare(kind: "cades", document: "{}", certificate_der: leaf.der) }.to raise_error(Signatures::Signer::Unavailable)
    expect(fake.check_certificate(certificate_der: leaf.der).status).to eq("indeterminate")
    fake.unavailable = true
    expect { fake.health }.to raise_error(Signatures::Signer::Unavailable)
  end
end
