require "rails_helper"
require "webmock/rspec"

# ADR 0028 (spec 2026-10-05 §1, §3.3): login na API de recebimento do PEC
# (usuário/senha → cookie JSESSIONID). Erros nunca carregam senha nem corpo.
RSpec.describe Ledi::PecClient do
  let(:url) { "https://pec.cidade.gov.br/api/recebimento/login" }
  let(:client) { described_class.new(base_url: "https://pec.cidade.gov.br/", username: "rota", password: "senha-secreta") }

  it "200 com JSESSIONID: devolve a sessão; manda usuario/senha em JSON" do
    stub_request(:post, url).with(body: { usuario: "rota", senha: "senha-secreta" }.to_json,
                                  headers: { "Content-Type" => "application/json" })
                            .to_return(status: 200, headers: { "Set-Cookie" => "JSESSIONID=abc123; Path=/; Secure; HttpOnly" })
    expect(client.login.cookie).to eq("JSESSIONID=abc123")
  end

  it "401/403: Unauthorized" do
    stub_request(:post, url).to_return(status: 401, body: "usuário senha-secreta inválido")
    expect { client.login }.to raise_error(described_class::Unauthorized) { |e| expect(e.message).not_to include("senha-secreta") }
  end

  it "timeout e conexão recusada: Unreachable" do
    stub_request(:post, url).to_timeout
    expect { client.login }.to raise_error(described_class::Unreachable)
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
    expect { client.login }.to raise_error(described_class::Unreachable)
  end

  # Review Focus 2: proxy que responde 200 em HTML, sem cookie.
  it "200 sem cookie e 500: Failed com o status, sem o corpo" do
    stub_request(:post, url).to_return(status: 200, body: "<html>login</html>")
    expect { client.login }.to raise_error(described_class::Failed) { |e| expect(e.message).not_to include("html") }
    stub_request(:post, url).to_return(status: 500, body: "stack trace com senha-secreta")
    expect { client.login }.to raise_error(described_class::Failed) { |e|
      expect(e.status).to eq(500)
      expect(e.message).not_to include("senha-secreta")
    }
  end

  it "inspect nunca mostra a senha" do
    expect(client.inspect).not_to include("senha-secreta")
  end

  it "a sessão nunca mostra o JSESSIONID em inspect, to_s, interpolação nem pp" do
    stub_request(:post, url).to_return(status: 200, headers: { "Set-Cookie" => "JSESSIONID=abc123; Path=/" })
    session = client.login
    expect(session.cookie).to eq("JSESSIONID=abc123")
    shown = [ session.inspect, session.to_s, "#{session}", [ session ].inspect, session.pretty_inspect ]
    shown.each { |text| expect(text).not_to include("abc123") }
    expect(session.inspect).to include("[FILTERED]")
  end
end
