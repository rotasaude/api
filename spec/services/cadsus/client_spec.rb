require "rails_helper"
require "webmock/rspec"

# ADR 0028 (spec 2026-10-05 §7): CADSUS por PDQv3 (SOAP, WS-Security) ou
# simulado em dev/test. Do retorno só saem CNS, nascimento e sexo — em memória.
RSpec.describe Cadsus::Client do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:city) do
    City.find_by(slug: TEST_CITY_A.slug) ||
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
  end

  def credential!(username = "rota")
    IntegrationCredential.create!(kind: "cadsus", secret: { "username" => username, "password" => "senha-pdq" },
                                  set_by_user: admin, set_at: Time.current)
  end

  it "sem credencial: Unavailable" do
    expect { Cadsus::Client.for(city) }.to raise_error(Cadsus::Unavailable)
  end

  describe Cadsus::Simulated do
    it "casos fixos: achado determinístico, não achado, fora do ar, credencial recusada" do
      credential!
      client = Cadsus::Client.for(city)
      record = client.lookup("52998224725")
      expect(record.cns).to satisfy { |cns| Professionals::Cns.valid?(cns) }
      expect(client.lookup("52998224725")).to eq(record)
      expect(%w[female male]).to include(record.sex)
      expect(client.lookup(Cadsus::Simulated::NOT_FOUND_CPF)).to be_nil
      expect { client.lookup(Cadsus::Simulated::UNAVAILABLE_CPF) }.to raise_error(Cadsus::Unavailable)
      expect(client.health_check).to eq(:ok)
      expect { Cadsus::Simulated.new(username: "recusado").health_check }.to raise_error(Cadsus::Unauthorized)
    end
  end

  describe Cadsus::SoapPdq do
    let(:url) { Cadsus::SoapPdq::HOMOLOGATION_URL }
    let(:client) { described_class.new(url: url, username: "rota", password: "senha-pdq") }
    def fixture(name) = File.read(Rails.root.join("spec/fixtures/cadsus/#{name}"))

    it "consulta por CPF com WS-Security e lê CNS, nascimento e sexo" do
      stub = stub_request(:post, url).with { |req|
        req.body.include?('root="2.16.840.1.113883.13.237" extension="52998224725"') &&
          req.body.include?("<wsse:Username>rota</wsse:Username>")
      }.to_return(status: 200, body: fixture("pdq_found.xml"))

      record = client.lookup("52998224725")

      expect(stub).to have_been_requested
      expect(record).to eq(Cadsus::Record.new(cns: "700000000000005", birth_date: Date.new(1980, 5, 17), sex: "female"))
    end

    it "sem paciente: nil" do
      stub_request(:post, url).to_return(status: 200, body: fixture("pdq_not_found.xml"))
      expect(client.lookup("52998224725")).to be_nil
    end

    it "401/403 ou Fault de segurança: Unauthorized; 5xx e timeout: Unavailable; nenhuma mensagem traz senha" do
      stub_request(:post, url).to_return(status: 401, body: "senha-pdq")
      expect { client.lookup("52998224725") }.to raise_error(Cadsus::Unauthorized) { |e| expect(e.message).not_to include("senha-pdq") }
      fault = '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><soap:Fault>' \
              "<soap:Reason><soap:Text>FailedAuthentication: The security token could not be authenticated</soap:Text>" \
              "</soap:Reason></soap:Fault></soap:Body></soap:Envelope>"
      stub_request(:post, url).to_return(status: 500, body: fault)
      expect { client.lookup("52998224725") }.to raise_error(Cadsus::Unauthorized)
      stub_request(:post, url).to_return(status: 503, body: "fora")
      expect { client.lookup("52998224725") }.to raise_error(Cadsus::Unavailable)
      stub_request(:post, url).to_timeout
      expect { client.lookup("52998224725") }.to raise_error(Cadsus::Unavailable)
      expect(client.inspect).not_to include("senha-pdq")
    end

    it "erros de rede além do timeout viram Unavailable sem vazar senha" do
      [ Net::WriteTimeout, Errno::EPIPE, Errno::ENETUNREACH, Net::ProtocolError, Errno::ECONNRESET, OpenSSL::SSL::SSLError ].each do |error|
        stub_request(:post, url).to_raise(error)
        expect { client.lookup("52998224725") }.to raise_error(Cadsus::Unavailable) { |e|
          expect(e.message).not_to include("senha-pdq")
        }
      end
    end

    it "2xx sem resposta PDQ (HTML de proxy, corpo vazio, XML truncado): Unavailable, nunca nil nem :ok" do
      [ "<html><body>Bem-vindo</body></html>", "", "<soap:Envelope><soap:Body><PRPA_IN" ].each do |body|
        stub_request(:post, url).to_return(status: 200, body: body)
        expect { client.lookup("52998224725") }.to raise_error(Cadsus::Unavailable)
        expect { client.health_check }.to raise_error(Cadsus::Unavailable)
      end
    end

    it "default_url: homologação, ou o que a configuração mandar; produção usa a constante de produção" do
      allow(Rails.application.config.x).to receive(:cadsus_pdq_url).and_return(nil)
      expect(described_class.default_url).to eq(described_class::HOMOLOGATION_URL)
      allow(Rails.application.config.x).to receive(:cadsus_pdq_url).and_return(described_class::PRODUCTION_URL)
      expect(described_class.default_url).to eq(described_class::PRODUCTION_URL)
      expect(File.read(Rails.root.join("config/environments/production.rb"))).to include(described_class::PRODUCTION_URL)
    end

    it "endereço inválido: Unavailable sem repetir a URL" do
      [ "http://exemplo.com:porta/x?token=segredo-na-url", "sem-esquema", "" ].each do |bad|
        bad_client = described_class.new(url: bad, username: "rota", password: "senha-pdq")
        expect { bad_client.lookup("52998224725") }.to raise_error(Cadsus::Unavailable) { |e|
          expect(e.message).not_to include("segredo-na-url")
          expect(e.message).not_to include(bad) if bad.present?
        }
      end
    end
  end
end
