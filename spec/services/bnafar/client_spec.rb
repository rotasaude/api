require "rails_helper"
require "webmock/rspec"

# SI-BNAFAR (módulo 27b, Task 8): Basic -> jwt, expires_in em ms ou s, 401 uma
# vez, lotes POST/PUT/DELETE e consulta de protocolo. As specs falam com o
# FakeBnafar::App em processo (WebMock#to_rack); nenhuma bate em URL real.
RSpec.describe Bnafar::Client, type: :model do
  let(:password) { "senha-super-secreta-27b" }
  let(:username) { "usuario-secreto-27b" }
  let(:ibge) { "4106902" }
  let!(:city) { pharmacy_city! }
  let(:fake) { fake_bnafar! }
  let(:environment) { "production" }
  let(:client) { Bnafar::Client.for(city, environment: environment) }

  def record(code: "10", cnes: "2384299", lot: "L1", cnpj: "11222333000181")
    { "estabelecimento" => { "cnes" => cnes, "tipo" => "F" },
      "caracterizacao" => { "codigoOrigem" => code, "dataSaida" => Date.current.iso8601, "estabelecimentoDestino" => cnes, "tipoSaida" => "S-CA" },
      "itens" => [ { "codigoOrigem" => "1", "numero" => "BR0270616", "terminologia" => "OBM", "codigoAmpp" => nil, "codigoVmp" => "123",
                     "registroAnvisa" => "1234567890123", "tipoProduto" => "B", "lote" => lot, "dataValidade" => "2027-01-31",
                     "cnpjFabricante" => cnpj, "nomeFabricanteInternacional" => nil, "quantidade" => 10, "valorUnitario" => 1.5,
                     "siglaProgramaSaude" => "AF", "iums" => [] } ] }
  end

  def credential!(env = "production", user: username, pass: password)
    IntegrationCredential.create!(kind: "bnafar", environment: env, secret: { "username" => user, "password" => pass },
                                  set_by_user: pharmacy_admin!, set_at: Time.current)
  end

  before do
    Bnafar::Client.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_BNAFAR_URL").and_return(FAKE_BNAFAR_BASE)
    fake
    credential!
    Platform::Features.set!(city: city, key: "bnafar_mock", enabled: true, maintainer: ledi_maintainer!)
  end

  describe "token" do
    it "expires_in em ms (1.800.000) e em s (1.800): vale 28 min (menos a margem de 2 min)" do
      expect(Bnafar::Client.token_lifetime(1_800_000)).to eq(28 * 60)
      expect(Bnafar::Client.token_lifetime(1_800)).to eq(28 * 60)
      expect(Bnafar::Client.token_lifetime(100)).to eq(0)
    end

    it "o token guardado serve até vencer e depois é pedido de novo" do
      now = 1000.0
      allow(client).to receive(:monotonic).and_return(now)
      first = client.token!
      expect(client.token!).to eq(first)
      expect(fake.log.count { |verb, path, _| verb == "POST" && path.end_with?("/jwtauth/auth") }).to eq(1)
      allow(client).to receive(:monotonic).and_return(now + (28 * 60) + 1)
      expect(client.token!).not_to eq(first)
    end

    it "expires_in em segundos (fake em :s) também vale" do
      fake.expires_in_unit = :s
      fake.expires_in = 1_800
      client.token!
      expect(client.token!(fresh: false)).to be_present
      expect(fake.log.count { |_, path, _| path.end_with?("/jwtauth/auth") }).to eq(1)
    end

    it "homologação e produção dão tokens diferentes (cache por ambiente)" do
      credential!("homologation")
      prod = Bnafar::Client.for(city, environment: "production").token!
      hom = Bnafar::Client.for(city, environment: "homologation").token!
      expect(prod).not_to eq(hom)
      expect(fake.log.count { |_, path, _| path.end_with?("/jwtauth/auth") }).to eq(2)
    end

    it "trocar a senha descarta o token" do
      client.token!
      IntegrationCredential.find_by!(kind: "bnafar").update!(secret: { "username" => username, "password" => "outra-senha-27b" }, set_at: Time.current + 1)
      Bnafar::Client.for(city, environment: "production").token!
      expect(fake.log.count { |_, path, _| path.end_with?("/jwtauth/auth") }).to eq(2)
    end

    it "fresh: true ignora o guardado" do
      client.token!
      client.token!(fresh: true)
      expect(fake.log.count { |_, path, _| path.end_with?("/jwtauth/auth") }).to eq(2)
    end

    it "senha recusada (401 no jwtauth) levanta Unauthorized; queda levanta Unavailable" do
      fake.failures.push(401)
      expect { client.token!(fresh: true) }.to raise_error(Bnafar::Errors::Unauthorized)
      fake.failures.push(503)
      expect { client.token!(fresh: true) }.to raise_error(Bnafar::Errors::Unavailable)
    end

    it "sem credencial ou sem URL da plataforma: NotConfigured" do
      IntegrationCredential.where(kind: "bnafar").delete_all
      expect { client }.to raise_error(Bnafar::Errors::NotConfigured)
      credential!
      expect { Bnafar::Client.for(city, environment: "production", settings: nil) }.to raise_error(Bnafar::Errors::NotConfigured)
    end
  end

  describe "lotes" do
    it "post_batch aceito traz o protocolo e a situação" do
      response = client.post_batch(subject: "exit", ibge: ibge, records: [ record ])
      expect(response).to have_attributes(status: :accepted, protocol: be_a(Integer), situation: "1", error_codes: [])
      expect(fake.received.last).to include(method: "POST", path: "/bnafar/produto/ibge/#{ibge}/saida-lote")
    end

    it "posição vai para posicao-estoque-lote; put_batch para o mesmo caminho" do
      client.put_batch(subject: "position", ibge: ibge, records: [ { "codigo" => 1 }.merge(record) ])
      expect(fake.received.last).to include(method: "PUT", path: "/bnafar/produto/ibge/#{ibge}/posicao-estoque-lote")
    end

    it "delete_batch manda ?codigos= e nenhum corpo" do
      client.delete_batch(subject: "exit", ibge: ibge, codes: [ 5001, 5002 ])
      expect(fake.received.last).to include(method: "DELETE", path: "/bnafar/produto/ibge/#{ibge}/saida-lote", query: { "codigos" => "5001,5002" })
    end

    it "assunto desconhecido é erro de programação" do
      expect { client.post_batch(subject: "entry", ibge: ibge, records: [ record ]) }.to raise_error(ArgumentError)
    end

    it "400 vira rejected só com os códigos que casam MSG_CODE, nunca o texto" do
      response = client.post_batch(subject: "exit", ibge: ibge, records: [])
      expect(response.status).to eq(:rejected)
      expect(response.error_codes).to eq([])
      many = Array.new(1001) { |i| record(code: i.to_s) }
      response = client.post_batch(subject: "exit", ibge: ibge, records: many)
      expect(response).to have_attributes(status: :rejected, error_codes: [ "MSG62" ])
      expect(response.inspect).not_to include("limite")
    end

    it "detail: processamento em duas consultas, com os itens processados" do
      protocol = client.post_batch(subject: "exit", ibge: ibge, records: [ record, record(code: "11", lot: "RECUSA") ]).protocol
      first = client.detail(ibge: ibge, protocol: protocol)
      expect(first).to have_attributes(status: :accepted, protocol: protocol, situation: "2", items: [])
      second = client.detail(ibge: ibge, protocol: protocol)
      expect(second.situation).to eq("4")
      expect(second.items).to match([
        a_hash_including(origin_code: "10", position: 0, success: true, bnafar_code: be_a(Integer)),
        a_hash_including(origin_code: "11", position: 1, success: false)
      ])
    end

    it "inconsistencies: a página traz os códigos MSG, não mensagem nem valor rejeitado" do
      protocol = client.post_batch(subject: "exit", ibge: ibge, records: [ record(lot: "RECUSA") ]).protocol
      2.times { client.detail(ibge: ibge, protocol: protocol) }
      page = client.inconsistencies(ibge: ibge, protocol: protocol, page: 0)
      expect(page.status).to eq(:accepted)
      expect(page.error_codes).to eq(%w[MSG09 MSG47])
      expect(page.items).to eq([ { origin_code: "10", position: 0, codes: %w[MSG09 MSG47] } ])
      expect(page.pages).to eq(1)
      expect(page.inspect).not_to include("RECUSA")
      expect(page.items.to_s).not_to include("RECUSA")
    end

    it "422 com MSG12: error_codes == [MSG12], nunca a mensagem" do
      stub_request(:post, %r{/saida-lote}).to_return(status: 422, headers: { "content-type" => "application/json" },
                                                     body: JSON.generate("http-status" => 422, "erro-mensagem" => "MSG12 - O CNPJ não consta no cadastro da Receita Federal."))
      response = client.post_batch(subject: "exit", ibge: ibge, records: [ record ])
      expect(response).to have_attributes(status: :rejected, error_codes: [ "MSG12" ])
      expect(response.to_s + response.inspect).not_to include("CNPJ")
    end

    it "cai: 5xx, conexão recusada e timeout viram transient" do
      client.token!
      fake.failures.push(503)
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:transient)
      fake.failures.push(:refused)
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:transient)
      stub_request(:post, %r{/saida-lote}).to_timeout
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:transient)
    end

    it "token guardado e 401: uma repetição com token novo aceita" do
      client.token!
      fake.failures.push(401)
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:accepted)
      expect(fake.log.count { |_, path, _| path.end_with?("/jwtauth/auth") }).to eq(2)
    end

    it "dois 401 (guardado e novo) viram unauthorized, e o token é descartado" do
      client.token!
      fake.failures.push(401, nil, 401) # lote, jwtauth, lote
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:unauthorized)
      client.token!
      expect(fake.log.count { |_, path, _| path.end_with?("/jwtauth/auth") }).to eq(3)
    end

    it "403 vira unauthorized sem repetir; senha recusada no jwtauth também" do
      client.token!
      fake.failures.push(403)
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:unauthorized)
      fake.failures.push(401)
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:unauthorized)
    end

    it "jwtauth fora do ar vira transient" do
      fake.failures.push(503)
      expect(client.post_batch(subject: "exit", ibge: ibge, records: [ record ]).status).to eq(:transient)
    end
  end

  describe "sigilo" do
    it "inspect, to_s, pretty_print e as_json do cliente e da resposta sem senha, usuário, token nem URL" do
      token = client.token!
      response = client.post_batch(subject: "exit", ibge: ibge, records: [ record ])
      [ client, response, client.settings ].each do |object|
        text = [ object.inspect, object.to_s, object.pretty_inspect ].join(" ")
        expect(text).not_to include(password)
        expect(text).not_to include(username)
        expect(text).not_to include(token)
        expect(text).not_to include("fake-bnafar")
        expect(text).not_to include("jwtauth")
      end
      expect(response.as_json.to_s).not_to include(token)
      expect(client.settings.as_json.to_s).not_to include("fake-bnafar")
    end

    it "nada da senha nem do token no log do Rails" do
      sink = ActiveSupport::Logger.new(logs = StringIO.new)
      Rails.logger.broadcast_to(sink)
      token = client.token!
      client.post_batch(subject: "exit", ibge: ibge, records: [ record ])
      expect(logs.string).not_to include(password)
      expect(logs.string).not_to include(token)
    ensure
      Rails.logger.stop_broadcasting_to(sink) if sink
    end

    it "erro de rede não carrega a URL" do
      stub_request(:post, %r{/jwtauth/auth}).to_raise(SocketError.new("getaddrinfo fake-bnafar.test"))
      expect { client.token!(fresh: true) }.to raise_error(Bnafar::Errors::Unavailable) { |e| expect(e.message).not_to include("fake-bnafar") }
    end
  end

  describe Bnafar::Config do
    it "simulado com bnafar_mock ligado: as duas URLs da base do simulado" do
      settings = described_class.for_city(city, environment: "production", env: "test")
      expect(settings.simulated).to be(true)
      expect(settings.auth_url).to eq("#{FAKE_BNAFAR_BASE}/jwtauth/auth")
      expect(settings.api_url).to eq("#{FAKE_BNAFAR_BASE}/bnafar")
    end

    it "sem o simulado, lê as credenciais da plataforma por ambiente; sem elas, nil" do
      Platform::Features.set!(city: city, key: "bnafar_mock", enabled: false, maintainer: ledi_maintainer!)
      expect(described_class.for_city(city, environment: "production", env: "test")).to be_nil
      creds = { homologation: { auth_url: "https://hom.test/jwtauth/auth", api_url: "https://hom.test/bnafar/" },
                production: { auth_url: "https://prod.test/jwtauth/auth", api_url: "https://prod.test/bnafar" } }
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:bnafar).and_return(creds)
      hom = described_class.for_city(city, environment: "homologation", env: "test")
      expect(hom).to have_attributes(auth_url: "https://hom.test/jwtauth/auth", api_url: "https://hom.test/bnafar", simulated: false)
      expect(described_class.for_city(city, environment: "production", env: "test").api_url).to eq("https://prod.test/bnafar")
    end

    it "http só fora de produção; produção exige https" do
      Platform::Features.set!(city: city, key: "bnafar_mock", enabled: false, maintainer: ledi_maintainer!)
      creds = { production: { auth_url: "http://prod.test/jwtauth/auth", api_url: "http://prod.test/bnafar" } }
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:bnafar).and_return(creds)
      expect(described_class.for_city(city, environment: "production", env: "production")).to be_nil
      expect(described_class.for_city(city, environment: "production", env: "test")).to be_present
    end
  end

  describe Bnafar::Mock do
    it "on? segue o interruptor utilizável do simulado" do
      expect(described_class).to respond_to(:on?)
      expect(described_class.on?(nil)).to be(false)
    end
  end

  describe Bnafar::Environment do
    it "sem a tabela bnafar_settings: production" do
      expect(described_class.current(env: "test")).to eq("production")
    end

    it "em produção é sempre production, mesmo com a tabela dizendo outra coisa" do
      allow(ApplicationRecord.connection).to receive(:data_source_exists?).and_call_original
      allow(ApplicationRecord.connection).to receive(:data_source_exists?).with("bnafar_settings").and_return(true)
      allow(ApplicationRecord.connection).to receive(:select_value).and_return("homologation")
      expect(described_class.current(env: "production")).to eq("production")
      expect(described_class.current(env: "test")).to eq("homologation")
    end

    it "allowed?: homologation só fora de produção" do
      expect(described_class.allowed?("homologation", env: "test")).to be(true)
      expect(described_class.allowed?("homologation", env: "staging")).to be(true)
      expect(described_class.allowed?("homologation", env: "production")).to be(false)
      expect(described_class.allowed?("production", env: "production")).to be(true)
      expect(described_class.allowed?("outro", env: "test")).to be(false)
    end
  end

  describe Bnafar::Evidence do
    it "curl leva o placeholder do token, nunca o real, e o status e o corpo sanitizado" do
      real = client.token!
      text = described_class.curl(method: "POST", url: "https://hom.test/bnafar/produto/ibge/1/saida-lote", body: [ record ],
                                  status: 200, response: "ok 98765432100 fim", environment: "homologation")
      expect(text).to include("-H 'Authorization: jwt <TOKEN>'", "# HTTP 200", "curl -X POST 'https://hom.test/bnafar/produto/ibge/1/saida-lote'")
      expect(text).to include("***")
      expect(text).not_to include(real)
      expect(text).not_to include("98765432100")
    end

    it "login leva -u '<USUARIO>:<SENHA>'" do
      text = described_class.login(url: "https://hom.test/jwtauth/auth", status: 200, environment: "homologation")
      expect(text).to include("-u '<USUARIO>:<SENHA>'", "# HTTP 200")
      expect(text).not_to include(password)
    end

    it "login nunca contém o access_token devolvido pelo fake" do
      token = client.token!(fresh: true)
      text = described_class.login(url: "https://hom.test/jwtauth/auth", status: 200, environment: "homologation")
      expect(text).not_to include(token)
      expect(text).not_to include("access_token")
    end

    it "curl não repete campo de token nem JWT da resposta" do
      jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c3VhcmlvIn0.assinaturaxyz"
      body = JSON.generate("access_token" => jwt, "token" => "outro-segredo", "msg" => jwt)
      text = described_class.curl(method: "GET", url: "https://hom.test/a", body: nil, status: 200, response: body, environment: "homologation")
      expect(text).not_to include(jwt)
      expect(text).not_to include("outro-segredo")
      expect(text).not_to include("assinaturaxyz")
    end

    it "só em homologação: em produção devolve vazio" do
      expect(described_class.curl(method: "POST", url: "https://x.test/a", body: [], environment: "production")).to eq("")
      expect(described_class.login(url: "https://x.test/a", environment: "production")).to eq("")
    end

    it "aspas simples no corpo são escapadas" do
      text = described_class.curl(method: "POST", url: "https://hom.test/a", body: { "a" => "d'agua" }, environment: "homologation")
      expect(text).to include("d'\\''agua")
    end
  end

  describe Bnafar::Homologation do
    let(:mapping) { described_class.mapping }

    it "o mapeamento vem da massa de homologação, marcado a conferir" do
      expect(mapping).to include("ibge" => "520010", "cnes" => "2384043", "a_conferir" => true)
      expect(mapping["products"]).to be_present
      expect(mapping["program"]).to be_present
    end

    it "apply troca CNES de origem e destino, produto e programa; não muda o original" do
      original = record(cnes: "9999999")
      swapped = described_class.apply(original, mapping: mapping)
      expect(swapped.dig("estabelecimento", "cnes")).to eq("2384043")
      expect(swapped.dig("caracterizacao", "estabelecimentoDestino")).to eq("2384043")
      item = swapped["itens"].first
      product = mapping["products"].first
      expect(item).to include("numero" => "", "terminologia" => "OBM", "codigoAmpp" => nil, "codigoVmp" => product["codigo_vmp"],
                              "registroAnvisa" => nil, "tipoProduto" => product["tipo_produto"], "siglaProgramaSaude" => "ESP")
      expect(item["codigoVmp"]).to eq("@brasil20774161856")
      expect(original.dig("estabelecimento", "cnes")).to eq("9999999")
      expect(original["itens"].first["numero"]).to eq("BR0270616")
    end

    it "apply aceita a lista de registros e a posição (sem destino)" do
      position = record.tap { |r| r["caracterizacao"] = { "codigoOrigem" => "1", "dataPosicaoEstoque" => "2026-11-24" } }
      result = described_class.apply([ position, record ], mapping: mapping)
      expect(result.size).to eq(2)
      expect(result.first["caracterizacao"]).to eq(position["caracterizacao"])
      expect(result.first.dig("estabelecimento", "cnes")).to eq("2384043")
    end
  end
end
