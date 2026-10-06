require "rails_helper"

# ADR 0028 / API de transmissão do PEC: POST /api/v1/recebimento/ficha,
# multipart com o campo `ficha` (arquivo <uuid>.esus) e o cookie da sessão,
# como no exemplo oficial ExemploEnvioApi.java. Stuba Net::HTTP.start (como
# spec/services/whatsapp/outbound_spec.rb).
RSpec.describe Ledi::PecClient, "#deliver" do
  let(:client) { described_class.new(base_url: "https://pec.cidade.gov.br", username: "rota", password: "senha-secreta") }
  let(:http) { instance_double(Net::HTTP) }
  let(:sent) { [] }

  before { allow(Net::HTTP).to receive(:start).and_yield(http) }

  it "envia o binário como multipart `ficha` com o nome do arquivo e o cookie" do
    allow(http).to receive(:request) { |req| sent << req; instance_double(Net::HTTPCreated, code: "201", body: "") }
    bytes = "\x0B\x00\x01\xFF".b

    reply = client.deliver(cookie: "JSESSIONID=abc", filename: "1234567-u.esus", bytes: bytes)

    expect(reply).to eq(Ledi::PecClient::Reply.new(status: 201, body: ""))
    req = sent.sole
    expect(req.path).to eq("/api/v1/recebimento/ficha")
    expect(req["Cookie"]).to eq("JSESSIONID=abc")
    boundary = req["Content-Type"][/\Amultipart\/form-data; boundary=(\S+)\z/, 1]
    expect(boundary).to be_present
    expect(req.body.b).to include(%(name="ficha"; filename="1234567-u.esus").b, bytes, "--#{boundary}--".b)
    expect(req.body).not_to include("senha-secreta")
  end

  it "devolve o status e o corpo de uma recusa" do
    allow(http).to receive(:request).and_return(instance_double(Net::HTTPBadRequest, code: "400", body: "CNES inválido"))
    expect(client.deliver(cookie: "c", filename: "f.esus", bytes: "x").to_h).to eq(status: 400, body: "CNES inválido")
  end

  it "timeout, conexão recusada e TLS viram Unreachable" do
    [ Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError, SocketError ].each do |error|
      allow(http).to receive(:request).and_raise(error)
      expect { client.deliver(cookie: "c", filename: "f.esus", bytes: "x") }
        .to raise_error(Ledi::PecClient::Unreachable), error.name
    end
  end

  # Net::ProtocolError ficou de fora de propósito: é a base de toda a família
  # Net::HTTP*Error e engoliria erros que não são de rede.
  it "escrita com timeout, pipe quebrado e rede inalcançável também viram Unreachable" do
    [ Net::WriteTimeout, Errno::EPIPE, Errno::ENETUNREACH ].each do |error|
      allow(http).to receive(:request).and_raise(error)
      expect { client.deliver(cookie: "c", filename: "f.esus", bytes: "x") }
        .to raise_error(Ledi::PecClient::Unreachable), error.name
    end
  end

  it "base_url malformada vira Unreachable sem vazar a URL" do
    bad = described_class.new(base_url: "https://usuario:segredo@pec .cidade.gov.br", username: "rota", password: "senha-secreta")
    expect { bad.deliver(cookie: "c", filename: "f.esus", bytes: "x") }
      .to raise_error(Ledi::PecClient::Unreachable) { |e|
        expect(e.message).not_to include("segredo")
        expect(e.message).not_to include("cidade.gov.br")
      }
    expect { bad.login }.to raise_error(Ledi::PecClient::Unreachable)
    expect(Net::HTTP).not_to have_received(:start)
  end

  it "CA local só em development/test" do
    allow(http).to receive(:request).and_return(instance_double(Net::HTTPCreated, code: "201", body: ""))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("LEDI_PEC_CA_FILE").and_return("/tmp/ca.pem")
    client.deliver(cookie: "c", filename: "f.esus", bytes: "x")
    expect(Net::HTTP).to have_received(:start).with("pec.cidade.gov.br", 443, hash_including(ca_file: "/tmp/ca.pem"))
  end
end
