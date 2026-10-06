require "rails_helper"
require "webmock/rspec"

# ADR 0028 (spec 2026-10-05 §1, §3.3): login na API de recebimento do PEC
# (usuário/senha → cookie JSESSIONID). Erros nunca carregam senha nem corpo.
RSpec.describe Ledi::PecClient do
  let(:url) { "https://pec.cidade.gov.br/api/recebimento/login" }
  let(:client) { described_class.new(base_url: "https://pec.cidade.gov.br/", username: "rota", password: "senha-secreta") }

  it "200 com JSESSIONID: devolve a sessão; manda usuario/senha como formulário, nunca JSON" do
    stub_request(:post, url).with(body: URI.encode_www_form(usuario: "rota", senha: "senha-secreta"),
                                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
                            .to_return(status: 200, headers: { "Set-Cookie" => "JSESSIONID=abc123; Path=/; Secure; HttpOnly" })
    expect(client.login.cookie).to eq("JSESSIONID=abc123")
  end

  it "400/401/403: Unauthorized (o PEC 5.5 responde 400 a credencial errada); a mensagem não traz a senha" do
    [ 400, 401, 403 ].each do |status|
      stub_request(:post, url).to_return(status: status, body: "usuário senha-secreta inválido")
      expect { client.login }.to raise_error(described_class::Unauthorized) { |e| expect(e.message).not_to include("senha-secreta") }
    end
  end

  it "timeout e conexão recusada: Unreachable" do
    stub_request(:post, url).to_timeout
    expect { client.login }.to raise_error(described_class::Unreachable)
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
    expect { client.login }.to raise_error(described_class::Unreachable)
  end

  it "URL do PEC malformada ou sem http(s): InvalidUrl (não Unreachable), sem a URL na mensagem, no login e no envio" do
    [ "http://exemplo com/x", "", "ftp://pec.cidade.gov.br" ].each do |bad|
      bad_client = described_class.new(base_url: bad, username: "rota", password: "senha-secreta")
      expect { bad_client.login }.to raise_error(described_class::InvalidUrl) do |e|
        expect(e).not_to be_a(described_class::Unreachable)
        expect(e.message).not_to include("exemplo")
        expect(e.message).not_to include("cidade.gov.br")
      end
      expect { bad_client.deliver(cookie: "JSESSIONID=x", filename: "a.esus", bytes: "x") }.to raise_error(described_class::InvalidUrl)
    end
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
