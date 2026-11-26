require "rails_helper"
require "base64"
require_relative "../../lib/fake_bnafar/app"

# O SI-BNAFAR simulado (módulo 27b, Task 7): token Basic -> jwt, lote de
# posição e de saída com protocolo, processamento em duas consultas,
# inconsistências por marcador, janela de 30 dias (contada do ENVIO do original,
# Q25) e quedas por `failures`.
RSpec.describe FakeBnafar::App, type: :model do
  let(:now) { Time.utc(2026, 11, 25, 12) }
  let(:app) { described_class.new(clock: -> { now }) }
  let(:mock) { Rack::MockRequest.new(app) }
  let(:password) { "senha-super-secreta-27b" }
  let(:ibge) { "4106902" }
  let(:exit_path) { "/bnafar/produto/ibge/#{ibge}/saida-lote" }
  let(:position_path) { "/bnafar/produto/ibge/#{ibge}/posicao-estoque-lote" }

  # R12: a janela do simulado é a mesma do app (o fake não carrega o app, sem
  # ActiveSupport; a igualdade fica presa aqui).
  it "WINDOW_DAYS é o Bnafar::Catalog::CORRECTION_DAYS" do
    expect(described_class::WINDOW_DAYS).to eq(Bnafar::Catalog::CORRECTION_DAYS)
  end

  def basic(user: "usuario-fake", pass: password) = "Basic #{Base64.strict_encode64("#{user}:#{pass}")}"
  def login(**) = mock.post("/jwtauth/auth", "HTTP_AUTHORIZATION" => basic(**))
  def token = JSON.parse(login.body).fetch("access_token")
  def json(response) = JSON.parse(response.body)

  def call(verb, path, body: nil, token: self.token)
    opts = { "HTTP_AUTHORIZATION" => "jwt #{token}", "CONTENT_TYPE" => "application/json" }
    opts[:input] = JSON.generate(body) if body
    mock.request(verb, path, opts)
  end

  def item(**over)
    { "codigoOrigem" => "1", "numero" => "BR0270616", "terminologia" => "OBM", "codigoAmpp" => nil, "codigoVmp" => "123",
      "registroAnvisa" => "1234567890123", "tipoProduto" => "B", "lote" => "L1", "dataValidade" => "2027-01-31",
      "cnpjFabricante" => "11222333000181", "nomeFabricanteInternacional" => nil, "quantidade" => 10,
      "valorUnitario" => 1.5, "siglaProgramaSaude" => "AF", "iums" => [] }.merge(over.transform_keys(&:to_s))
  end

  def exit_record(code = "10", date: "2026-11-24", cnes: "2384299", items: [ item ])
    { "estabelecimento" => { "cnes" => cnes, "tipo" => "F" },
      "caracterizacao" => { "codigoOrigem" => code, "dataSaida" => date, "estabelecimentoDestino" => "2384299", "tipoSaida" => "S-CA" },
      "itens" => items }
  end

  def position_record(code = "20", date: "2026-11-24", cnes: "2384299", items: [ item ])
    { "estabelecimento" => { "cnes" => cnes, "tipo" => "F" },
      "caracterizacao" => { "codigoOrigem" => code, "dataPosicaoEstoque" => date }, "itens" => items }
  end

  def detail(protocol) = json(call("GET", "/bnafar/protocolo/ibge/#{ibge}/detalhar-processamento/#{protocol}"))
  def inconsistencies(protocol, page: 0, size: 100)
    json(call("GET", "/bnafar/protocolo/ibge/#{ibge}/inconsistencias/#{protocol}?pageNumber=#{page}&pageSize=#{size}"))
  end

  def send_exit(records = [ exit_record ]) = json(call("POST", exit_path, body: records)).fetch("protocolo")

  def processed(protocol)
    detail(protocol)
    detail(protocol)
  end

  it "emite o token com Basic, em ms; sem Basic ou com Basic malformado, 401" do
    response = login
    expect(response.status).to eq(200)
    expect(json(response)).to include("scope" => "read write", "expires_in" => 1_800_000, "access_token" => be_a(String))
    expect(mock.post("/jwtauth/auth").status).to eq(401)
    expect(mock.post("/jwtauth/auth", "HTTP_AUTHORIZATION" => "Basic !!!").status).to eq(401)
    expect(mock.post("/jwtauth/auth", "HTTP_AUTHORIZATION" => "Bearer abc").status).to eq(401)
  end

  it "troca a unidade do expires_in para segundos e o token vale pelo prazo dito" do
    app.expires_in = 1800
    app.expires_in_unit = :s
    expect(json(login)).to include("expires_in" => 1800)
    live = token
    expect(call("GET", "/bnafar/protocolo/ibge/#{ibge}/detalhar-processamento/1", token: live).status).to eq(404)
    app.clock = -> { now + 1801 }
    expect(call("GET", "/bnafar/protocolo/ibge/#{ibge}/detalhar-processamento/1", token: live).status).to eq(401)
  end

  it "token vencido ou ausente dá 401" do
    old = token
    app.clock = -> { now + 1801 }
    expect(call("POST", exit_path, body: [ exit_record ], token: old).status).to eq(401)
    expect(mock.post(exit_path, input: "[]").status).to eq(401)
    expect(call("POST", exit_path, body: [ exit_record ], token: "qualquer").status).to eq(401)
  end

  it "o lote devolve o Protocolo; a 1a consulta é situação 2 e a 2a, situação 3 com codigoBnafar" do
    response = call("POST", exit_path, body: [ exit_record("10"), exit_record("11") ])
    expect(response.status).to eq(200)
    protocol = json(response)
    expect(protocol).to include("protocolo" => be_a(Integer), "situacao" => "1", "codigoIbge" => ibge, "tipoOperacao" => "1",
                                "tipoServico" => "2", "dataProtocolo" => start_with("2026-11-25T12:00:00"))
    first = detail(protocol["protocolo"])
    expect(first.dig("protocolo", "situacao")).to eq("2")
    expect(first["itensProcessados"]).to be_nil
    second = detail(protocol["protocolo"])
    expect(second.dig("protocolo", "situacao")).to eq("3")
    expect(second["processamento"]).to include("quantidadeItensTotal" => 2, "quantidadeItensSucesso" => 2, "quantidadeItensInconsistente" => 0)
    expect(second["itensProcessados"]).to match([
      include("codigoOrigem" => "10", "posicaoEnvio" => 0, "sucesso" => true, "codigoBnafar" => be_a(Integer)),
      include("codigoOrigem" => "11", "posicaoEnvio" => 1, "sucesso" => true, "codigoBnafar" => be_a(Integer))
    ])
    expect(second["itensProcessados"].map { |r| r["codigoBnafar"] }.uniq.size).to eq(2)
    expect(detail(protocol["protocolo"]).dig("protocolo", "situacao")).to eq("3")
  end

  it "a posição de estoque tem o mesmo ciclo (tipoServico 4)" do
    protocol = json(call("POST", position_path, body: [ position_record ]))
    expect(protocol).to include("tipoServico" => "4", "tipoOperacao" => "1")
    expect(processed(protocol["protocolo"]).dig("protocolo", "situacao")).to eq("3")
  end

  it "RECUSA no lote: MSG09, sucesso false, sem codigoBnafar (MSG47) e situação 4" do
    protocol = send_exit([ exit_record("10", items: [ item(lote: "RECUSA", codigoOrigem: "i1") ]) ])
    result = processed(protocol)
    expect(result.dig("protocolo", "situacao")).to eq("4")
    expect(result["itensProcessados"]).to eq([ { "codigoOrigem" => "10", "posicaoEnvio" => 0, "sucesso" => false } ])
    page = inconsistencies(protocol)
    expect(page).to include("pageNumber" => 0, "pageSize" => 100, "totalElements" => 1, "totalPages" => 1, "numberOfElements" => 1)
    entry = page["content"].first
    expect(entry).to include("codigoOrigem" => "10", "posicaoEnvio" => 0)
    expect(entry["inconsistencias"].map { |i| i["codigo"] }).to contain_exactly("MSG09", "MSG47")
    expect(entry["inconsistencias"].find { |i| i["codigo"] == "MSG09" }).to include("valorRejeitado" => "RECUSA", "posicaoEnvio" => 0, "codigoOrigem" => "i1")
  end

  it "CNES 0000000 dá MSG06 e CNPJ 00000000000000 dá MSG12 (registro parcial mantém o código)" do
    protocol = send_exit([ exit_record("10", cnes: "0000000"),
                           exit_record("11", items: [ item(cnpjFabricante: "00000000000000", codigoOrigem: "a"), item(codigoOrigem: "b") ]) ])
    result = processed(protocol)
    expect(result["itensProcessados"][0]).to include("sucesso" => false)
    expect(result["itensProcessados"][0]).not_to have_key("codigoBnafar")
    expect(result["itensProcessados"][1]).to include("sucesso" => false, "codigoBnafar" => be_a(Integer))
    codes = inconsistencies(protocol)["content"].to_h { |e| [ e["codigoOrigem"], e["inconsistencias"].map { |i| i["codigo"] } ] }
    expect(codes).to eq("10" => [ "MSG06" ], "11" => [ "MSG12" ])
  end

  it "mais de 1.000 registros: 400 MSG62; corpo inválido: 400" do
    response = call("POST", exit_path, body: Array.new(1001) { |i| exit_record(i.to_s) })
    expect(response.status).to eq(400)
    expect(json(response)).to include("http-status" => 400, "erro-mensagem" => start_with("MSG62"))
    expect(mock.post(exit_path, "HTTP_AUTHORIZATION" => "jwt #{token}", input: "{").status).to eq(400)
    expect(call("POST", exit_path, body: []).status).to eq(400)
    expect(call("POST", exit_path, body: Array.new(1000) { |i| exit_record(i.to_s) }).status).to eq(200)
  end

  it "mais itens que items_limit: MSG46 no registro, sem código" do
    protocol = send_exit([ exit_record("10", items: Array.new(21) { |i| item(codigoOrigem: i.to_s) }) ])
    expect(processed(protocol)["itensProcessados"]).to eq([ { "codigoOrigem" => "10", "posicaoEnvio" => 0, "sucesso" => false } ])
    expect(inconsistencies(protocol)["content"].first["inconsistencias"].map { |i| i["codigo"] }).to eq([ "MSG46" ])
    small = described_class.new(clock: -> { now }, items_limit: 2)
    expect(small.items_limit).to eq(2)
  end

  it "data fora de hoje e ontem: MSG73; hoje e ontem passam" do
    protocol = send_exit([ exit_record("10", date: "2026-11-23"), exit_record("11", date: "2026-11-24"), exit_record("12", date: "2026-11-25") ])
    result = processed(protocol)
    expect(result["itensProcessados"].map { |r| r["sucesso"] }).to eq([ false, true, true ])
    expect(inconsistencies(protocol)["content"].map { |e| [ e["codigoOrigem"], e["inconsistencias"].first["codigo"] ] }).to eq([ [ "10", "MSG73" ] ])
  end

  it "pagina as inconsistências" do
    protocol = send_exit(Array.new(3) { |i| exit_record(i.to_s, cnes: "0000000") })
    processed(protocol)
    first = inconsistencies(protocol, page: 0, size: 2)
    expect(first).to include("totalElements" => 3, "totalPages" => 2, "numberOfElements" => 2)
    expect(inconsistencies(protocol, page: 1, size: 2)["content"].size).to eq(1)
  end

  it "as inconsistências só aparecem depois do processamento" do
    protocol = send_exit([ exit_record("10", cnes: "0000000") ])
    expect(inconsistencies(protocol)["content"]).to eq([])
    detail(protocol)
    detail(protocol)
    expect(inconsistencies(protocol)["content"].size).to eq(1)
  end

  it "protocolo desconhecido: 404 com MSG19" do
    response = call("GET", "/bnafar/protocolo/ibge/#{ibge}/detalhar-processamento/999")
    expect(response.status).to eq(404)
    expect(json(response)["erro-mensagem"]).to start_with("MSG19")
  end

  describe "exclusão" do
    def accepted_codes(protocol) = processed(protocol)["itensProcessados"].map { |r| r["codigoBnafar"] }

    it "DELETE por codigos devolve o protocolo de exclusão e marca protocoloExclusao" do
      original = send_exit([ exit_record("10"), exit_record("11") ])
      codes = accepted_codes(original)
      response = call("DELETE", "#{exit_path}?codigos=#{codes.join(',')}")
      expect(response.status).to eq(200)
      deletion = json(response)
      expect(deletion).to include("tipoOperacao" => "3", "tipoServico" => "2", "situacao" => "1")
      result = processed(deletion["protocolo"])
      expect(result.dig("protocolo", "situacao")).to eq("3")
      expect(result["itensProcessados"]).to all(include("sucesso" => true, "protocoloExclusao" => original))
      expect(result["itensProcessados"].map { |r| r["codigoBnafar"] }).to eq(codes)
    end

    it "aceita codigos repetidos na query e a exclusão por protocolo" do
      original = send_exit([ exit_record("10"), exit_record("11") ])
      codes = accepted_codes(original)
      one = json(call("DELETE", "#{exit_path}?codigos=#{codes[0]}"))
      expect(processed(one["protocolo"])["itensProcessados"].size).to eq(1)
      rest = json(call("DELETE", "#{exit_path}?protocolo=#{original}"))
      result = processed(rest["protocolo"])
      expect(result["itensProcessados"]).to match([ include("sucesso" => false), include("sucesso" => true, "codigoBnafar" => codes[1]) ])
      expect(inconsistencies(rest["protocolo"])["content"].first["inconsistencias"].first["codigo"]).to eq("MSG20")
    end

    it "sem protocolo nem codigos: 400 MSG38" do
      response = call("DELETE", exit_path)
      expect(response.status).to eq(400)
      expect(json(response)["erro-mensagem"]).to start_with("MSG38")
    end

    it "registro enviado há 31 dias: MSG18 na exclusão e MSG16 na alteração (prazo conta do envio)" do
      original = send_exit([ exit_record("10") ])
      code = accepted_codes(original).first
      app.clock = -> { now + (31 * 86_400) }
      fresh = token
      deletion = json(call("DELETE", "#{exit_path}?codigos=#{code}", token: fresh))
      result = processed(deletion["protocolo"])
      expect(result["itensProcessados"]).to eq([ { "codigoOrigem" => "10", "posicaoEnvio" => 0, "sucesso" => false } ])
      expect(inconsistencies(deletion["protocolo"])["content"].first["inconsistencias"].first["codigo"]).to eq("MSG18")
      change = exit_record("10").merge("codigo" => code)
      put = json(call("PUT", exit_path, body: [ change ], token: fresh))
      expect(put).to include("tipoOperacao" => "2")
      processed(put["protocolo"])
      expect(inconsistencies(put["protocolo"])["content"].first["inconsistencias"].first["codigo"]).to eq("MSG16")
    end

    it "com 30 dias a alteração e a exclusão ainda passam" do
      original = send_exit([ exit_record("10"), exit_record("11") ])
      codes = accepted_codes(original)
      app.clock = -> { now + (30 * 86_400) }
      fresh = token
      put = json(call("PUT", exit_path, body: [ exit_record("10").merge("codigo" => codes[0]) ], token: fresh))
      expect(processed(put["protocolo"])["itensProcessados"]).to match([ include("sucesso" => true, "codigoBnafar" => codes[0]) ])
      del = json(call("DELETE", "#{exit_path}?codigos=#{codes[1]}", token: fresh))
      expect(processed(del["protocolo"])["itensProcessados"]).to match([ include("sucesso" => true, "protocoloExclusao" => original) ])
    end
  end

  it "guarda os corpos em received, por verbo e caminho" do
    send_exit([ exit_record("10") ])
    call("PUT", exit_path, body: [ exit_record("10").merge("codigo" => 1) ])
    expect(app.received.map { |r| [ r[:method], r[:path] ] }).to eq([ [ "POST", exit_path ], [ "PUT", exit_path ] ])
    expect(app.received.first[:body]).to eq([ exit_record("10") ])
    app.reset!
    expect(app.received).to be_empty
  end

  it "failures simulam queda: status e conexão recusada" do
    live = token
    app.failures.push(503, :refused)
    expect(call("POST", exit_path, body: [ exit_record ], token: live).status).to eq(503)
    expect { call("POST", exit_path, body: [ exit_record ], token: live) }.to raise_error(Errno::ECONNREFUSED)
    expect(call("POST", exit_path, body: [ exit_record ], token: live).status).to eq(200)
  end

  it "o log nunca contém Basic, jwt, o token nem a senha" do
    live = token
    send_exit([ exit_record ])
    call("DELETE", "#{exit_path}?codigos=1", token: live)
    login
    expect(app.log).not_to be_empty
    text = app.log.flatten.map(&:to_s).join(" ") + app.log.inspect + app.inspect
    expect(text).not_to include("Basic ")
    expect(text).not_to include("jwt ")
    expect(text).not_to include(password)
    expect(text).not_to include(live)
    expect(app.log.first).to eq([ "POST", "/jwtauth/auth", {} ])
  end

  it "rota desconhecida dá 404" do
    expect(call("GET", "/bnafar/outra").status).to eq(404)
  end

  it "o helper fake_bnafar! serve o simulado por WebMock em fake-bnafar.test:8095" do
    served = fake_bnafar!(described_class.new(clock: -> { now }))
    uri = URI("#{FAKE_BNAFAR_BASE}/jwtauth/auth")
    response = Net::HTTP.start(uri.host, uri.port) do |http|
      http.post(uri.path, "", "Authorization" => basic)
    end
    expect(response.code).to eq("200")
    expect(served.log.last).to eq([ "POST", "/jwtauth/auth", {} ])
  end

  describe "config.ru" do
    let(:path) { Rails.root.join("lib/fake_bnafar/config.ru").to_s }

    it "sobe fora de produção" do
      expect(Rack::Builder.parse_file(path)).to be_present
    end

    it "aborta com RACK_ENV=production" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("RAILS_ENV").and_return(nil)
      allow(ENV).to receive(:[]).with("RACK_ENV").and_return("production")
      expect { Rack::Builder.parse_file(path) }.to raise_error(SystemExit)
    end
  end
end
