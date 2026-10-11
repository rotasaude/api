# lib/fake_sncr/app.rb
# SNCR SIMULADO (ADR 0034; Manual da API SNCR 3ª ed.): login do prescritor
# (página que faz as vezes do gov.br), session_id de uso único e 30 s preso
# ao Origin do client_url, token de 30 s sem refresh, bloco de 1.000 números
# de RCE/RET com 201, 3 pedidos por mês por inscrição e tipo, esgotamento por
# UF e inscrição divergente. Usado pelas specs (WebMock#to_rack) e pelo
# serviço fake-sncr do compose de dev (config.ru). Nunca em produção. Sem
# ActiveSupport: roda sozinho no puma.
require "json"
require "securerandom"
require "uri"
require "cgi"
require "rack"

module FakeSncr
  class App
    TOKEN_TTL = 30
    SESSION_TTL = 30
    MONTHLY_LIMIT = 3
    BLOCK = 1000
    CONSELHOS = %w[CRM CRMV CRO].freeze
    TIPOS = { "RCE" => 1, "RET" => 2 }.freeze
    UF_CODES = { "RO" => 11, "AC" => 12, "AM" => 13, "RR" => 14, "PA" => 15, "AP" => 16, "TO" => 17, "MA" => 21, "PI" => 22,
                 "CE" => 23, "RN" => 24, "PB" => 25, "PE" => 26, "AL" => 27, "SE" => 28, "BA" => 29, "MG" => 31, "ES" => 32,
                 "RJ" => 33, "SP" => 35, "PR" => 41, "SC" => 42, "RS" => 43, "MS" => 50, "MT" => 51, "GO" => 52, "DF" => 53 }.freeze
    MESSAGES = {
      ok: "Numeração gerada com sucesso.", session: "Sessão inválida ou expirada", domain_refused: "Domínio não autorizado",
      unauthorized: "Não autorizado.", limit: "Usuário atingiu o limite máximo de receita para o tipo de receita no mês atual.",
      exhausted: "Faixa de numeração esgotada para a UF.", mismatch: "Inscrição fornecida é diferente da autenticada.",
      conselho_nulo: "Conselho não pode ser nulo.", conselho: "Conselho inválido", tipo_nulo: "Tipo de receita não pode ser nulo.",
      tipo: "Tipo da receita inválido. Valores permitidos: [RCE, RET]", uf_nulo: "UF não pode ser nulo.",
      documento_nulo: "Documento não pode ser nulo.", cnpj_nulo: "CNPJ não pode ser nulo.", cnpj: "CNPJ inválido."
    }.freeze

    attr_reader :log
    attr_accessor :clock, :failures, :exhausted_ufs, :mismatch_documents

    def initialize(start_block: nil, clock: -> { Time.now })
      @start_block = start_block
      @clock = clock
      @mutex = Mutex.new
      reset!
    end

    def reset!
      @mutex.synchronize do
        @pending = {}
        @sessions = {}
        @tokens = {}
        @requests = Hash.new(0)
        @blocks = {}
        @last_block = nil
        @log = []
      end
      @failures = []
      @exhausted_ufs = []
      @mismatch_documents = []
    end

    # — Ganchos de teste (a pessoa passando pelo gov.br e o estado do SNCR) —

    def approve!(client_url)
      origin = origin_of(client_url) or raise ArgumentError, "client_url fora dos domínios aceitos"
      new_session(origin)
    end

    def issued_tokens = @mutex.synchronize { @tokens.keys }
    def repeat_last_block! = @mutex.synchronize { @blocks[@last_block] -= 1 if @last_block }

    def call(env)
      request = Rack::Request.new(env)
      failure = @mutex.synchronize do
        @log << [ request.request_method, request.path ]
        @failures.shift
      end
      raise Errno::ECONNREFUSED, "fake-sncr" if failure == :refused
      return json(failure, { mensagem: "Erro interno do servidor." }) if failure.is_a?(Integer)

      route(request)
    end

    def inspect = "#<FakeSncr::App>"

    private

    def now = @clock.call

    def route(request)
      path = request.path.sub(%r{\A.*?/(auth|numeracoes)/}, '/\1/')
      case [ request.request_method, path ]
      in [ "GET", "/auth/login" ] then login(request)
      in [ "GET", "/auth/login/decision" ] then decision(request)
      in [ "GET", "/auth/token" ] then token(request)
      in [ "POST", "/numeracoes/receita-especial-retencao" ] then numbers(request)
      else json(404, { mensagem: "Página não foi encontrada." })
      end
    end

    def login(request)
      client_url = request.params["client_url"].to_s
      origin = origin_of(client_url)
      return html(400, "<p>#{MESSAGES[:domain_refused]}</p>") unless origin

      id = SecureRandom.hex(8)
      @mutex.synchronize { @pending[id] = { client_url: client_url, origin: origin } }
      decision = "#{request.script_name}#{request.path}/decision?id=#{id}"
      html(200, <<~HTML)
        <h1>SNCR SIMULADO — desenvolvimento</h1>
        <p>Este é o SNCR simulado do ambiente de desenvolvimento. Não há gov.br aqui: continue como o profissional
        que pediu os números. Os números entregues são de <strong>numeração simulada — sem validade</strong>.</p>
        <p><a href="#{CGI.escapeHTML("#{decision}&approve=1")}">Entrar (simulado)</a> ·
        <a href="#{CGI.escapeHTML("#{decision}&approve=0")}">Cancelar</a></p>
      HTML
    end

    def decision(request)
      pending = @mutex.synchronize { @pending.delete(request.params["id"].to_s) }
      return html(400, "<p>#{MESSAGES[:session]}</p>") unless pending

      separator = pending[:client_url].include?("?") ? "&" : "?"
      location = if request.params["approve"] == "1"
                   "#{pending[:client_url]}#{separator}session_id=#{new_session(pending[:origin])}"
                 else
                   "#{pending[:client_url]}#{separator}error=access_denied"
                 end
      [ 302, { "location" => location }, [] ]
    end

    def token(request)
      session = @mutex.synchronize { @sessions.delete(request.params["session_id"].to_s) }
      return json(400, { error: MESSAGES[:session] }) unless session && session[:expires_at] > now
      return json(403, { error: MESSAGES[:domain_refused] }) unless request.get_header("HTTP_ORIGIN") == session[:origin]

      token = SecureRandom.urlsafe_base64(32)
      @mutex.synchronize { @tokens[token] = now + TOKEN_TTL }
      json(200, { access_token: token, token_type: "Bearer" })
    end

    def numbers(request)
      token = request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")
      expires_at = @mutex.synchronize { @tokens[token] }
      return json(401, { mensagem: MESSAGES[:unauthorized] }) unless expires_at && expires_at > now

      body = parse(request)
      error = validation_error(body)
      return json(400, { mensagem: error }) if error
      return json(404, { mensagem: MESSAGES[:mismatch] }) if @mismatch_documents.include?(body["documento"])
      return json(400, { mensagem: MESSAGES[:exhausted] }) if @exhausted_ufs.include?(body["uf"])

      first, last = @mutex.synchronize do
        key = [ body["conselho"], body["documento"], body["uf"], body["tipo"], now.strftime("%Y%m") ]
        next nil if @requests[key] >= MONTHLY_LIMIT

        @requests[key] += 1
        range(body["tipo"], body["uf"])
      end
      return json(400, { mensagem: MESSAGES[:limit] }) unless first

      json(201, { inicio: first, fim: last, quantidade: BLOCK, mensagem: MESSAGES[:ok] })
    end

    # Chamado com o mutex tomado.
    def range(tipo, uf)
      key = [ tipo, uf ]
      @blocks[key] = (@start_block || rand(100..8_999)) unless @blocks.key?(key)
      index = @blocks[key]
      @blocks[key] += 1
      @last_block = key
      prefix = "#{now.strftime('%y%m')}.#{TIPOS.fetch(tipo)}-#{UF_CODES.fetch(uf)}."
      [ "#{prefix}#{format('%07d', (index * BLOCK) + 1)}", "#{prefix}#{format('%07d', (index + 1) * BLOCK)}" ]
    end

    def validation_error(body)
      return MESSAGES[:conselho_nulo] if body["conselho"].to_s.empty?
      return MESSAGES[:conselho] unless CONSELHOS.include?(body["conselho"])
      return MESSAGES[:tipo_nulo] if body["tipo"].to_s.empty?
      return MESSAGES[:tipo] unless TIPOS.key?(body["tipo"])
      return MESSAGES[:uf_nulo] if body["uf"].to_s.empty?
      return "UF não encontrada: #{body['uf']}" unless UF_CODES.key?(body["uf"])
      return MESSAGES[:documento_nulo] if body["documento"].to_s.empty?
      return MESSAGES[:cnpj_nulo] if body["cnpj"].to_s.empty?

      MESSAGES[:cnpj] unless cnpj?(body["cnpj"].to_s)
    end

    # DV do CNPJ (numérico e alfanumérico, IN RFB 2.229/2024: valor = código ASCII − 48).
    def cnpj?(value)
      return false unless value.match?(/\A[0-9A-Z]{12}[0-9]{2}\z/)

      digits = value.chars.map { |char| char.ord - 48 }
      [ 12, 13 ].all? do |size|
        weights = (2..9).cycle.first(size).reverse
        sum = digits.first(size).zip(weights).sum { |digit, weight| digit * weight }
        check = sum % 11 < 2 ? 0 : 11 - (sum % 11)
        check == digits[size]
      end
    end

    def new_session(origin)
      id = SecureRandom.urlsafe_base64(24)
      @mutex.synchronize { @sessions[id] = { origin: origin, expires_at: now + SESSION_TTL } }
      id
    end

    # O SNCR aceita *.br (e localhost/127.0.0.1 em dev); o simulado aceita também *.localhost.
    def origin_of(url)
      uri = URI.parse(url)
      return nil unless %w[http https].include?(uri.scheme) && uri.host
      return nil unless uri.host.end_with?(".br") || uri.host == "localhost" || uri.host.end_with?(".localhost") || uri.host == "127.0.0.1"

      default = (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
      "#{uri.scheme}://#{uri.host}#{default ? '' : ":#{uri.port}"}"
    rescue URI::InvalidURIError
      nil
    end

    def parse(request)
      parsed = JSON.parse(request.body.read.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def json(status, body) = [ status, { "content-type" => "application/json; charset=utf-8" }, [ JSON.generate(body) ] ]

    def html(status, body)
      page = "<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\"><title>SNCR SIMULADO — desenvolvimento</title></head>" \
             "<body style=\"font-family:system-ui;max-width:40rem;margin:2rem auto\">#{body}</body></html>"
      [ status, { "content-type" => "text/html; charset=utf-8" }, [ page ] ]
    end
  end
end
