require "rails_helper"
require "webmock/rspec"
require_relative "../../../lib/fake_rnds/app"

# Transporte da RNDS (módulo 29, Desvio 14): token por mTLS no EHR-AUTH e POST
# do Bundle no EHR-Services. As specs falam com o FakeRnds::App em processo
# (WebMock#to_rack) ou com Net::HTTP trocado; nenhuma bate em URL real.
RSpec.describe Rnds::Client do
  FAKE_RNDS_BASE = "http://fake-rnds.test:8094".freeze
  REAL_AUTH = "https://ehr-auth.rnds.test".freeze
  REAL_EHR = "https://ehr-services.rnds.test".freeze

  let!(:city) { vaccination_city!(rnds: true) }
  let(:fake) { FakeRnds::App.new(timeout_delay: 0) }
  let(:room) { vaccine_room! }
  let(:dose) { create_immunization!(room, immunobiological_code: "42", dose_code: "1", strategy: "1", care_group: "121", route: "3", site: "18", maternal_condition: "1") }
  let(:bundle) { Rnds::Bundle.build(immunization: dose, kind: "application", cnes: "1234567", now: Time.current) }
  let(:client) { described_class.for(city) }
  let(:cns) { "700000000000005" }

  before do
    described_class.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_RNDS_URL").and_return(FAKE_RNDS_BASE)
    stub_request(:any, /\A#{Regexp.escape(FAKE_RNDS_BASE)}/).to_rack(fake)
  end

  it "token e envio: 201 vira accepted com o id do Location" do
    response = client.post_bundle(bundle, practitioner_cns: cns)
    expect(response).to have_attributes(status: :accepted, rnds_id: fake.accepted.last[:id], error: nil)
    expect(fake.log.last).to eq([ "POST", "/api/fhir/r4/Bundle", { "authorization" => cns, "x-authorization-server" => "Bearer #{fake.issued_tokens.last}" } ])
  end

  it "422 vira rejected com a mensagem limpa, sem o CPF" do
    bundle["entry"].last["resource"]["lotNumber"] = "RECUSA"
    response = client.post_bundle(bundle, practitioner_cns: cns)
    expect(response).to have_attributes(status: :rejected, rnds_id: nil, error: "Lote inválido para o CPF ***")
  end

  it "5xx e recusa de conexão viram transient; 401 vira unauthorized" do
    fake.failures.push(503, :refused, 401)
    expect(3.times.map { client.post_bundle(bundle, practitioner_cns: cns).status }).to eq(%i[transient transient unauthorized])
  end

  it "timeout vira transient" do
    bundle["entry"].last["resource"]["lotNumber"] = "TIMEOUT"
    expect(client.post_bundle(bundle, practitioner_cns: cns)).to have_attributes(status: :transient, error: nil)
  end

  it "401 com token do cache: descarta, repete uma vez com token novo e aceita" do
    expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:accepted)
    fake.failures.push(401)
    expect(client.post_bundle(bundle, practitioner_cns: cns)).to have_attributes(status: :accepted)
    expect(fake.issued_tokens.size).to eq(2)
    expect(fake.accepted.size).to eq(2)
  end

  it "403 de novo com o token novo vira unauthorized (uma só repetição) e o token é descartado" do
    expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:accepted)
    fake.failures.push(403, nil, 403) # POST, token novo, POST
    expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:unauthorized)
    expect(fake.log.count { |entry| entry[1].end_with?("/Bundle") }).to eq(3)
    expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:accepted)
    expect(fake.issued_tokens.size).to eq(3)
  end

  it "401 com token recém-emitido não repete" do
    fake.failures.push(nil, 401)
    expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:unauthorized)
    expect(fake.log.count { |entry| entry[1].end_with?("/Bundle") }).to eq(1)
  end

  it "guarda o token por 25 minutos e o renova depois" do
    2.times { client.post_bundle(bundle, practitioner_cns: cns) }
    expect(fake.issued_tokens.size).to eq(1)
    allow(Process).to receive(:clock_gettime).and_wrap_original { |m, *args| m.call(*args) + 26 * 60 }
    client.post_bundle(bundle, practitioner_cns: cns)
    expect(fake.issued_tokens.size).to eq(2)
  end

  it "token! devolve o token; recusa do EHR-AUTH vira Unauthorized; queda vira Unavailable" do
    expect(client.token!).to eq(fake.issued_tokens.last)
    fake.failures.push(401, 403, 503, :refused)
    [ Rnds::Errors::Unauthorized, Rnds::Errors::Unauthorized, Rnds::Errors::Unavailable, Rnds::Errors::Unavailable ].each do |error|
      expect { client.token!(fresh: true) }.to raise_error(error)
    end
  end

  it "CNS do vacinador malformado não vai à rede" do
    expect { client.post_bundle(bundle, practitioner_cns: "70 00\r\nX: y") }.to raise_error(ArgumentError)
    expect(fake.log).to be_empty
  end

  describe "por kind (26c)" do
    it "kind desconhecido não procura credencial" do
      expect { described_class.for(city, kind: "ledi") }.to raise_error(ArgumentError)
    end

    it "rnds_regulation sem credencial: NotConfigured; a da rnds não vale" do
      expect { described_class.for(city, kind: "rnds_regulation") }.to raise_error(Rnds::Errors::NotConfigured)
    end

    it "a rnds não tem responsible_cns" do
      expect(client.responsible_cns).to be_nil
    end

    context "com a credencial rnds_regulation gravada" do
      before do
        CityConnection.with(city) { rnds_regulation_credential!(responsible_cns: cns_regulation) }
      end

      let(:cns_regulation) { valid_cns(26) }

      it "usa o PFX dessa credencial e lê o responsible_cns dela" do
        regulation = described_class.for(city, kind: "rnds_regulation")
        der = lambda do |kind|
          credential = CityConnection.with(city) { IntegrationCredential.find_by!(kind: kind) }
          OpenSSL::PKCS12.new(credential.pfx_bytes, credential.pfx_password).certificate.to_der
        end
        expect(der.call("rnds_regulation")).not_to eq(der.call("rnds"))
        expect(regulation.send(:mtls)[:cert].to_der).to eq(der.call("rnds_regulation"))
        expect(client.send(:mtls)[:cert].to_der).to eq(der.call("rnds"))
        expect(regulation.responsible_cns).to eq(cns_regulation)
        expect(regulation.token!(fresh: true)).to be_present
        expect(regulation.inspect).not_to include(cns_regulation)
      end

      it "token da rnds não serve à rnds_regulation (cache separado)" do
        client.token!
        expect(fake.log.map(&:first)).to eq(%w[GET])
        described_class.for(city, kind: "rnds_regulation").token!
        expect(fake.log.map(&:first)).to eq(%w[GET GET])
        client.token!
        expect(fake.log.map(&:first)).to eq(%w[GET GET])
      end
    end
  end

  describe "regulação (26c): identifier_chain e delete_bundle" do
    let(:profile) { Regulation::RiraProfile.current }
    let(:system_url) { "#{profile.identifiers[:requester_prefix]}12345" }
    let(:responsible) { described_class::Identity.new(pfx: "x", password: "x", version: 1.0, responsible_cns: cns) }
    let(:regulation) { described_class.new(client.settings, responsible, key: [ city.id, "rnds_regulation", 1.0, true ]) }

    def rira(value: "mira-1", relates_to: nil)
      composition = { "resourceType" => "Composition", "meta" => { "profile" => [ profile.profiles[:composition] ] } }
      composition["relatesTo"] = [ { "code" => "replaces", "targetReference" => { "reference" => "Composition/#{relates_to}" } } ] if relates_to
      { "resourceType" => "Bundle", "type" => "document", "identifier" => { "system" => system_url, "value" => value }, "entry" => [ { "resource" => composition } ] }
    end

    it "identifier_chain lista os documentos sem o cns" do
      first = regulation.post_bundle(rira, practitioner_cns: cns).rnds_id
      second = regulation.post_bundle(rira(relates_to: first), practitioner_cns: cns).rnds_id
      chain = regulation.identifier_chain(system: system_url, value: "mira-1", doc_type: "RIRA")
      expect(chain.status).to eq(:ok)
      expect(chain.documents.map { |d| [ d.id, d.status, d.replaces ] }).to contain_exactly([ first, "entered-in-error", nil ], [ second, "final", first ])
      expect(chain.documents.first.date).to be_present
      expect(chain.inspect + chain.documents.inspect).not_to include(cns)
      expect(fake.log.last).to eq([ "GET", "/api/identifier", { "authorization" => cns, "x-authorization-server" => "Bearer #{fake.issued_tokens.last}" } ])
    end

    it "identifier_chain sem documento é ok e vazio; 401 vira unauthorized; 5xx vira transient" do
      expect(regulation.identifier_chain(system: system_url, value: "nada", doc_type: "RIRA")).to have_attributes(status: :ok, documents: [])
      fake.failures.push(503)
      expect(regulation.identifier_chain(system: system_url, value: "nada", doc_type: "RIRA").status).to eq(:transient)
      fake.failures.push(401, 401)
      expect(regulation.identifier_chain(system: system_url, value: "nada", doc_type: "RIRA").status).to eq(:unauthorized)
    end

    it "sem responsible_cns (credencial rnds) não consulta nem apaga" do
      expect { client.identifier_chain(system: system_url, value: "x", doc_type: "RIRA") }.to raise_error(ArgumentError)
      expect { client.delete_bundle("abc") }.to raise_error(ArgumentError)
      expect(fake.log).to be_empty
    end

    it "delete_bundle 204 -> accepted; de novo -> rejected com o EHR-ERR825; id malformado não vai à rede" do
      id = regulation.post_bundle(rira, practitioner_cns: cns).rnds_id
      expect(regulation.delete_bundle(id)).to have_attributes(status: :accepted, rnds_id: id, error: nil)
      refused = regulation.delete_bundle(id)
      expect(refused.status).to eq(:rejected)
      expect(Rnds::Errors.codes(refused.error)).to eq([ "EHR-ERR825" ])
      log_size = fake.log.size
      expect { regulation.delete_bundle("../token") }.to raise_error(ArgumentError)
      expect(fake.log.size).to eq(log_size)
    end

    it "a substituição repetida volta rejected com o EDS-MSG009" do
      first = regulation.post_bundle(rira, practitioner_cns: cns).rnds_id
      regulation.post_bundle(rira(relates_to: first), practitioner_cns: cns)
      again = regulation.post_bundle(rira(relates_to: first), practitioner_cns: cns)
      expect(again.status).to eq(:rejected)
      expect(Rnds::Errors.codes(again.error)).to eq([ "EDS-MSG009" ])
    end
  end

  describe "Rnds::Errors.codes" do
    it "acha EDS-MSG009 e EHR-ERR825 e nunca devolve o texto" do
      text = "(EDS-MSG009) O documento 3f2a já foi substituído. CPF 12345678901; (EHR-ERR825) fora do estado final"
      expect(Rnds::Errors.codes(text)).to eq(%w[EDS-MSG009 EHR-ERR825])
    end

    it "sem código (ou nil) -> rejected; repetido conta uma vez" do
      expect(Rnds::Errors.codes("A RNDS recusou o envio")).to eq([ "rejected" ])
      expect(Rnds::Errors.codes(nil)).to eq([ "rejected" ])
      expect(Rnds::Errors.codes("EHR-ERR999 e EHR-ERR999")).to eq([ "EHR-ERR999" ])
    end

    it "o ERROR_CODE da regulação é o mesmo padrão" do
      expect(Regulation::RndsLimits::ERROR_CODE).to equal(Rnds::Errors::CODE)
      expect(Rnds::Errors::CODE).to match("EDS-MSG009")
      expect(Rnds::Errors::CODE).not_to match("EHR-ERR9999")
    end
  end

  it "sem URL da plataforma ou sem credencial: NotConfigured" do
    allow(ENV).to receive(:[]).with("FAKE_RNDS_URL").and_return(nil)
    expect { described_class.for(city) }.to raise_error(Rnds::Errors::NotConfigured)
    allow(ENV).to receive(:[]).with("FAKE_RNDS_URL").and_return(FAKE_RNDS_BASE)
    CityConnection.with(city) { IntegrationCredential.where(kind: "rnds").delete_all }
    expect { described_class.for(city) }.to raise_error(Rnds::Errors::NotConfigured)
  end

  it "nada sensível em inspect, to_s, pretty_print nem na mensagem dos erros" do
    pfx_password = CityConnection.with(city) { IntegrationCredential.find_by!(kind: "rnds").pfx_password }
    token = client.token!
    response = client.post_bundle(bundle, practitioner_cns: cns)
    fake.failures.push(:refused)
    failed = client.post_bundle(bundle, practitioner_cns: cns)
    texts = [ client.inspect, client.to_s, client.pretty_inspect, client.settings.inspect, client.settings.to_s, response.inspect, failed.inspect,
              failed.error.to_s ]
    texts.each do |text|
      expect(text).not_to include(FAKE_RNDS_BASE, "fake-rnds.test", pfx_password, token, cns)
    end
    fake.failures.push(:refused)
    begin
      client.token!
    rescue Rnds::Errors::Error => e
      expect(e.message).not_to include("fake-rnds", "8094", "ECONNREFUSED")
    end
  end

  describe "configuração real" do
    before do
      Platform::Features.set!(city: city, key: "rnds_mock", enabled: false, maintainer: ledi_maintainer!)
      allow(Rnds::Config).to receive(:credentials).and_return("auth_url" => REAL_AUTH, "ehr_url" => REAL_EHR)
    end

    it "fala https com o certificado da cidade (mTLS) e verificação padrão" do
      captured = []
      ok = Net::HTTPOK.new("1.1", "200", "OK")
      allow(ok).to receive(:body).and_return(JSON.generate("access_token" => "tok-real"))
      allow(Net::HTTP).to receive(:start) { |host, port, **opts, &blk| captured << [ host, port, opts ]; blk ? blk.call(instance_double(Net::HTTP, request: ok)) : ok }
      expect(client.token!).to eq("tok-real")
      host, port, opts = captured.last
      expect([ host, port ]).to eq([ "ehr-auth.rnds.test", 443 ])
      expect(opts).to include(use_ssl: true, open_timeout: 5, read_timeout: 20, cert: be_a(OpenSSL::X509::Certificate), key: be_a(OpenSSL::PKey::RSA))
      expect(opts).not_to include(verify_mode: OpenSSL::SSL::VERIFY_NONE)
    end

    it "Config: real exige https e as duas URLs; template de produção usa a UF da cidade" do
      expect(Rnds::Config.for_city(city)).to have_attributes(auth_url: REAL_AUTH, ehr_url: REAL_EHR, simulated: false)
      allow(Rnds::Config).to receive(:credentials).and_return("auth_url" => REAL_AUTH, "ehr_url_template" => "https://%{uf}.ehr.rnds.test")
      city.uf = "pr"
      expect(Rnds::Config.for_city(city).ehr_url).to eq("https://pr.ehr.rnds.test")
      allow(Rnds::Config).to receive(:credentials).and_return("auth_url" => "http://inseguro.test", "ehr_url" => REAL_EHR)
      expect(Rnds::Config.for_city(city, env: "production")).to be_nil
      allow(Rnds::Config).to receive(:credentials).and_return("auth_url" => REAL_AUTH)
      expect(Rnds::Config.for_city(city)).to be_nil
    end
  end

  describe "alertas TLS" do
    def raise_ssl(message) = allow(Net::HTTP).to receive(:start).and_raise(OpenSSL::SSL::SSLError.new(message))

    it "alerta de certificado de cliente vira Unauthorized (token!) e unauthorized (post_bundle)" do
      [ "SSL_connect returned=1 errno=0 state=error: tlsv1 alert unknown ca", "SSL_read: sslv3 alert bad certificate",
        "tlsv13 alert certificate required", "sslv3 alert certificate revoked", "sslv3 alert certificate expired",
        "sslv3 alert certificate unknown" ].each do |message|
        raise_ssl(message)
        expect { client.token!(fresh: true) }.to raise_error(Rnds::Errors::Unauthorized) { |e| expect(e.message).not_to include("alert") }
        expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:unauthorized)
      end
    end

    it "outros erros SSL (certificado do servidor, handshake) seguem Unavailable e transient" do
      [ "SSL_connect returned=1 errno=0 state=error: certificate verify failed (unable to get local issuer certificate)",
        "SSL_connect returned=1 errno=0 state=error: wrong version number" ].each do |message|
        raise_ssl(message)
        expect { client.token!(fresh: true) }.to raise_error(Rnds::Errors::Unavailable)
        expect(client.post_bundle(bundle, practitioner_cns: cns).status).to eq(:transient)
      end
    end
  end

  describe "Rnds::Config simulado" do
    it "usa FAKE_RNDS_URL nas duas pontas e esconde a URL no inspect" do
      settings = Rnds::Config.for_city(city)
      expect(settings).to have_attributes(auth_url: FAKE_RNDS_BASE, ehr_url: FAKE_RNDS_BASE, simulated: true)
      expect(settings.inspect).not_to include("fake-rnds")
      expect(Rnds::Config.for_city(city, env: "production")).to be_nil
    end
  end

  describe "Rnds::Errors.sanitize" do
    it "corta em 200 e troca 11 ou mais dígitos (também o CPF formatado) por ***" do
      expect(Rnds::Errors.sanitize("CPF 12345678901 e CNS 700000000000005 ok")).to eq("CPF *** e CNS *** ok")
      expect(Rnds::Errors.sanitize("CPF 123.456.789-01 recusado")).to eq("CPF *** recusado")
      expect(Rnds::Errors.sanitize("1234567890 fica")).to eq("1234567890 fica")
      expect(Rnds::Errors.sanitize("a" * 500).length).to eq(200)
      expect(Rnds::Errors.sanitize(("a" * 195) + "12345678901")).to eq(("a" * 195) + "***")
      expect(Rnds::Errors.sanitize(nil)).to eq("")
      expect(Rnds::Errors.sanitize("bytes \xFF ruins\n  linhas")).to end_with("ruins linhas")
    end
  end
end
