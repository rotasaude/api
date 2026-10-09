require "rails_helper"

# Contrato da API v0 do ITI (DOC-ICP-17.01; pesquisa §2; Task 0 Step 3):
# localização por CPF, autorização com PKCE S256, token, recuperação do
# certificado e assinatura RAW de hash. O falso confere PKCE, uso único e
# assina de verdade; a última spec usa respostas literais do documento.
RSpec.describe Signatures::Psc::Client do
  before { stub_psc! }

  let(:client) { described_class.for("vidaas") }
  let(:fake) { fake_psc }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  let(:redirect_uri) { "https://auth.rotasaude.test/signature/psc/callback" }
  let(:verifier) { SecureRandom.urlsafe_base64(48) }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }

  def url(scope, state: "st-#{SecureRandom.hex(4)}", lifetime: nil)
    client.authorize_url(state: state, challenge: challenge, scope: scope, login_hint: cpf, redirect_uri: redirect_uri,
                         lifetime: lifetime)
  end

  def token(scope, lifetime: nil)
    code = authorize_and_approve!(url(scope, lifetime: lifetime))
    client.exchange(code: code, verifier: verifier, redirect_uri: redirect_uri)
  end

  it "localiza o titular por CPF e registra a checagem" do
    expect(client.discover(cpf)).to be(true)
    fake.absent_cpfs << cpf
    expect(client.discover(cpf)).to be(false)
    expect(SignatureProviderCheck.find_by(provider: "vidaas")).to have_attributes(last_check_ok: true)
  end

  it "monta a URL de autorização com PKCE S256, CPF e tempo de vida" do
    query = URI.decode_www_form(URI(url("signature_session", state: "abc", lifetime: 43_200)).query).to_h
    expect(query).to include("response_type" => "code", "client_id" => FakePsc::App::CLIENT_ID, "state" => "abc",
                             "scope" => "signature_session", "code_challenge" => challenge,
                             "code_challenge_method" => "S256", "login_hint" => cpf, "lifetime" => "43200",
                             "redirect_uri" => redirect_uri)
    expect { url("qualquer") }.to raise_error(ArgumentError)
  end

  it "troca o código, lê o certificado e assina RAW o hash" do
    issued = token("signature_session", lifetime: 43_200)
    expect(issued.expires_in).to eq(43_200)
    expect(issued.inspect).not_to include(issued.access_token)
    entry = client.certificates(issued.access_token).sole
    expect(Signatures::CertificateInfo.parse(entry.der).cpf).to eq(cpf)
    digests = { "d1" => Digest::SHA256.digest("um"), "d2" => Digest::SHA256.digest("dois") }
    raw = client.sign(access_token: issued.access_token, certificate_alias: entry.certificate_alias, digests: digests)
    public_key = fake.leaf(cpf).certificate.public_key
    expect(digests.all? { |id, digest| public_key.verify_raw("SHA256", raw.fetch(id), digest) }).to be(true)
    expect(client.sign(access_token: issued.access_token, certificate_alias: cpf, digests: { "d3" => digests["d1"] }).keys)
      .to eq([ "d3" ]) # signature_session: várias chamadas
  end

  it "PKCE errado e código reusado são recusados (invalid_grant)" do
    code = authorize_and_approve!(url("single_signature"))
    expect { client.exchange(code: code, verifier: "outro-#{verifier}", redirect_uri: redirect_uri) }
      .to raise_error(Signatures::Psc::Rejected) { |e| expect(e.code).to eq("invalid_grant") }
    expect { client.exchange(code: code, verifier: verifier, redirect_uri: redirect_uri) }
      .to raise_error(Signatures::Psc::Rejected)
  end

  it "single_signature vale uma assinatura; multi_signature, uma chamada com vários hashes" do
    single = token("single_signature")
    client.sign(access_token: single.access_token, certificate_alias: cpf, digests: { "a" => Digest::SHA256.digest("a") })
    expect { client.sign(access_token: single.access_token, certificate_alias: cpf, digests: { "b" => Digest::SHA256.digest("b") }) }
      .to raise_error(Signatures::Psc::Unauthorized)
    multi = token("multi_signature")
    many = (1..100).to_h { |i| [ "h#{i}", Digest::SHA256.digest(i.to_s) ] }
    expect(client.sign(access_token: multi.access_token, certificate_alias: cpf, digests: many).size).to eq(100)
  end

  it "503, conexão recusada e token vencido: Unavailable/Unauthorized sem segredo na mensagem" do
    fake.failures.push(503, :refused)
    log = capture_log do
      expect { client.discover(cpf) }.to raise_error(Signatures::Psc::Unavailable) { |e| expect(e.message).not_to include(FakePsc::App::CLIENT_SECRET) }
      expect { client.discover(cpf) }.to raise_error(Signatures::Psc::Unavailable)
    end
    expect(SignatureProviderCheck.find_by(provider: "vidaas")).to have_attributes(last_check_ok: false)
    issued = token("signature_session")
    fake.expire_tokens!
    expect { client.certificates(issued.access_token) }.to raise_error(Signatures::Psc::Unauthorized)
    expect(log).not_to include(FakePsc::App::CLIENT_SECRET, cpf)
  end

  it "a página de autorização do falso se anuncia como PSC SIMULADO" do
    response = Net::HTTP.get_response(URI(url("signature_session")))
    expect(response.code).to eq("200")
    expect(response.body.force_encoding("UTF-8")).to include("PSC SIMULADO — desenvolvimento")
  end

  it "com o interruptor signature_psc_mock: o mesmo cliente fala com o PSC simulado" do
    city = stub_psc_mock!
    simulated = described_class.for("simulated", city: city)
    expect(simulated.discover(cpf)).to be(true)
    url = simulated.authorize_url(state: "sim-1", challenge: challenge, scope: "signature_session", login_hint: cpf,
                                  redirect_uri: redirect_uri)
    expect(url).to start_with("#{SignatureHelpers::PSC_BASES['simulated']}/v0/oauth/authorize?")
    code = authorize_and_approve!(url, key: "simulated")
    issued = simulated.exchange(code: code, verifier: verifier, redirect_uri: redirect_uri)
    expect(simulated.certificates(issued.access_token).sole.certificate_alias).to eq(cpf)
    expect(SignatureProviderCheck.find_by(provider: "simulated")).to have_attributes(last_check_ok: true)
    expect { described_class.for("vidaas") }.to raise_error(Signatures::Psc::Unavailable)
  end

  # api#55: o nome do titular vai só ao PSC simulado, no corpo do POST do
  # token (servidor a servidor, nunca na URL); o PSC real não o recebe.
  it "PSC real: o nome do titular nunca vai na troca do código" do
    code = authorize_and_approve!(url("single_signature"))
    client.exchange(code: code, verifier: verifier, redirect_uri: redirect_uri, holder_name: "Helena Duarte Moreira")
    expect(a_request(:post, "#{SignatureHelpers::PSC_BASES['vidaas']}/v0/oauth/token")
      .with { |req| !req.body.include?("Helena") && !req.body.include?("holder") }).to have_been_made.once
  end

  it "PSC simulado: e-CPF com o nome do titular (formato ICP); sem nome, o genérico; assina com a mesma chave" do
    city = stub_psc_mock!
    simulated = described_class.for("simulated", city: city)
    issue = lambda do |holder_name|
      authorize = simulated.authorize_url(state: "sim-#{SecureRandom.hex(4)}", challenge: challenge, scope: "signature_session",
                                          login_hint: cpf, redirect_uri: redirect_uri)
      expect(authorize).not_to include("Helena", "HELENA")
      code = authorize_and_approve!(authorize, key: "simulated")
      simulated.exchange(code: code, verifier: verifier, redirect_uri: redirect_uri, holder_name: holder_name)
    end
    named = issue.call("Helena: Duarte\u0000 Moreira")
    entry = simulated.certificates(named.access_token).sole
    info = Signatures::CertificateInfo.parse(entry.der)
    expect([ info.holder_name, info.cpf ]).to eq([ "HELENA DUARTE MOREIRA", cpf ])
    digest = Digest::SHA256.digest("um")
    raw = simulated.sign(access_token: named.access_token, certificate_alias: cpf, digests: { "d" => digest })
    expect(info.certificate.public_key.verify_raw("SHA256", raw.fetch("d"), digest)).to be(true)

    generic = Signatures::CertificateInfo.parse(simulated.certificates(issue.call(nil).access_token).sole.der)
    expect(generic.holder_name).to eq("PROFISSIONAL DE TESTE #{cpf[-4..]}")
  end

  it "lê as respostas no formato literal do DOC-ICP-17.01 (sem o falso)" do
    WebMock.reset!
    base = SignatureHelpers::PSC_BASES["vidaas"]
    der = test_pki.leaf_for(cpf).der
    stub_request(:post, "#{base}/v0/oauth/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "eyJ0eXAi", token_type: "Bearer", expires_in: 43_200, scope: "signature_session",
                         authorized_identification_type: "CPF", authorized_identification: cpf }.to_json)
    stub_request(:get, "#{base}/v0/oauth/certificate-discovery")
      .with(headers: { "Authorization" => "Bearer eyJ0eXAi" })
      .to_return(status: 200, body: { status: "S", certificates: [ { alias: "slot-1", certificate: Base64.strict_encode64(der) } ] }.to_json)
    # Array#== não usa o === do hash_including aninhado: confere o corpo à mão.
    stub_request(:post, "#{base}/v0/oauth/signature").with do |request|
      body = JSON.parse(request.body)
      body["certificate_alias"] == "slot-1" &&
        body["hashes"].map { |item| item.slice("id", "hash_algorithm", "signature_format") } ==
          [ { "id" => "x", "hash_algorithm" => "2.16.840.1.101.3.4.2.1", "signature_format" => "RAW" } ]
    end
      .to_return(status: 200, body: { certificate_alias: "slot-1", signatures: [ { id: "x", raw_signature: Base64.strict_encode64("RAW") } ] }.to_json)

    issued = client.exchange(code: "c", verifier: verifier, redirect_uri: redirect_uri)
    expect(issued).to have_attributes(access_token: "eyJ0eXAi", expires_in: 43_200, scope: "signature_session")
    expect(client.certificates("eyJ0eXAi").sole).to have_attributes(certificate_alias: "slot-1", der: der)
    expect(client.sign(access_token: "eyJ0eXAi", certificate_alias: "slot-1", digests: { "x" => Digest::SHA256.digest("x") }))
      .to eq("x" => "RAW")
  end
end

RSpec.describe "Redação de segredos (Psc::Token, Psc::CertificateEntry, Providers::Provider)" do
  it "pretty_inspect e to_s não mostram token, segredo nem DER" do
    token = Signatures::Psc::Token.new(access_token: "TOKEN-SEGREDO", expires_in: 60, scope: "single_signature")
    entry = Signatures::Psc::CertificateEntry.new(certificate_alias: "a", der: "DER-SEGREDO")
    provider = Signatures::Providers::Provider.new(key: "vidaas", client_id: "cid", client_secret: "CLIENT-SEGREDO",
                                                   base_url: "https://x.test", authorize_base_url: "https://x.test")
    [ token, entry, provider ].each do |value|
      expect([ value.pretty_inspect, value.to_s, "#{value}", value.inspect ].join).not_to match(/SEGREDO/)
    end
  end
end
