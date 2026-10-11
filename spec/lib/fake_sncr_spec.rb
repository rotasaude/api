# spec/lib/fake_sncr_spec.rb
require "rails_helper"

# O SNCR simulado imita a API real (Manual 3ª ed.; Desvio 1): login com
# página "SNCR SIMULADO", volta com session_id de uso único e 30 s, token
# preso ao Origin, token de 30 s, bloco de 1.000 com 201, 3 pedidos por mês
# por inscrição e tipo, esgotamento, inscrição divergente, CNPJ inválido.
RSpec.describe FakeSncr::App do
  let(:now) { Time.utc(2026, 10, 10, 12) }
  let(:app) { described_class.new(start_block: 1, clock: -> { now }) }
  let(:mock) { Rack::MockRequest.new(app) }
  let(:client_url) { "http://curitiba.localhost:5189/dashboard/sncr/callback" }
  let(:origin) { "http://curitiba.localhost:5189" }
  let(:inscricao) { { "conselho" => "CRM", "documento" => "12345", "uf" => "PR", "cnpj" => "11222333000181" } }

  def token_for(session_id, origin: self.origin) = mock.get("/api/v1/auth/token?session_id=#{session_id}", "HTTP_ORIGIN" => origin)

  def bearer
    JSON.parse(token_for(app.approve!(client_url)).body).fetch("access_token")
  end

  def block(tipo: "RCE", token: bearer, body: inscricao)
    mock.post("/api/v1/numeracoes/receita-especial-retencao", input: JSON.generate(body.merge("tipo" => tipo)),
                                                               "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}")
  end

  it "login mostra a página do simulado e volta com session_id; cancelar volta com error" do
    page = mock.get("/api/v1/auth/login?client_url=#{CGI.escape(client_url)}&state=abc")
    expect(page.status).to eq(200)
    expect(page.body).to include("SNCR SIMULADO — desenvolvimento", "numeração simulada")
    approve = page.body[%r{href="([^"]+approve=1[^"]*)"}, 1]
    back = mock.get(CGI.unescapeHTML(approve))
    expect(back.status).to eq(302)
    expect(back.location).to match(%r{\A#{Regexp.escape(client_url)}\?session_id=[\w-]+\z})
    deny = mock.get(CGI.unescapeHTML(mock.get("/api/v1/auth/login?client_url=#{CGI.escape(client_url)}").body[%r{href="([^"]+approve=0[^"]*)"}, 1]))
    expect(deny.location).to eq("#{client_url}?error=access_denied")
    expect(mock.get("/api/v1/auth/login?client_url=#{CGI.escape('https://evil.example.com/cb')}").status).to eq(400)
  end

  it "session_id: uso único, 30 s, preso ao Origin" do
    session_id = app.approve!(client_url)
    expect(token_for(session_id, origin: "http://outra.localhost:5189").status).to eq(403)
    session_id = app.approve!(client_url)
    response = token_for(session_id)
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to include("token_type" => "Bearer", "access_token" => be_a(String))
    expect(JSON.parse(token_for(session_id).body)).to eq("error" => "Sessão inválida ou expirada")
    late = app.approve!(client_url)
    app.clock = -> { now + 31 }
    expect(token_for(late).status).to eq(400)
  end

  it "bloco de 1.000 com 201; token de 30 s" do
    token = bearer
    response = block(token: token)
    expect(response.status).to eq(201)
    body = JSON.parse(response.body)
    expect(body).to eq("inicio" => "2610.1-41.0001001", "fim" => "2610.1-41.0002000", "quantidade" => 1000,
                       "mensagem" => "Numeração gerada com sucesso.")
    expect(JSON.parse(block(tipo: "RET").body)["inicio"]).to eq("2610.2-41.0001001")
    app.clock = -> { now + 31 }
    expect(block(token: token).status).to eq(401)
  end

  it "3 pedidos por mês por inscrição e tipo; esgotamento; inscrição divergente; validação" do
    3.times { expect(block.status).to eq(201) }
    limit = block
    expect([ limit.status, JSON.parse(limit.body)["mensagem"] ])
      .to eq([ 400, "Usuário atingiu o limite máximo de receita para o tipo de receita no mês atual." ])
    expect(block(tipo: "RET").status).to eq(201)
    app.exhausted_ufs << "SP"
    expect(JSON.parse(block(body: inscricao.merge("uf" => "SP")).body)["mensagem"]).to match(/esgotada/)
    app.mismatch_documents << "999"
    expect(block(body: inscricao.merge("documento" => "999")).status).to eq(404)
    expect(JSON.parse(block(body: inscricao.merge("cnpj" => "11222333000182")).body)["mensagem"]).to eq("CNPJ inválido.")
    expect(JSON.parse(block(body: inscricao.merge("conselho" => "COREN")).body)["mensagem"]).to eq("Conselho inválido")
  end

  it "repeat_last_block! devolve de novo a última faixa (incidente de 09/10); failures simulam queda" do
    first = JSON.parse(block.body)["inicio"]
    app.repeat_last_block!
    expect(JSON.parse(block.body)["inicio"]).to eq(first)
    token = bearer # o token sai antes: failures vale para toda chamada seguinte, inclusive o login
    app.failures << 503
    expect(block(token: token).status).to eq(503)
    app.failures << :refused
    expect { block(token: token) }.to raise_error(Errno::ECONNREFUSED)
  end

  it "o config.ru sobe fora de produção" do
    expect(Rack::Builder.parse_file(Rails.root.join("lib/fake_sncr/config.ru").to_s)).to be_present
  end
end
