# Transporte do SI-BNAFAR (módulo 27b, Task 8; manual v1.25). `POST {auth_url}`
# com Basic devolve `access_token` e `expires_in` (ms no manual; aceita-se ms e
# s: acima de MS_THRESHOLD é ms); as chamadas levam `Authorization: jwt <token>`.
# Lotes POST/PUT (corpo) e DELETE (`?codigos=`) em `{api_url}/produto/ibge/:ibge/
# (posicao-estoque-lote|saida-lote)`; consulta em `/protocolo/ibge/:ibge/...`.
# O token fica em memória do processo, por cidade, versão da credencial e
# ambiente, até `expires_in` menos TOKEN_MARGIN; um 401 com token guardado o
# descarta e repete UMA vez com token novo.
#
# `observer` (opcional; a evidência da homologação, Task 11) recebe cada
# chamada: verbo, URL (sem token: ele vai no header), corpo enviado, status e
# corpo recebido. No jwtauth, nem o corpo enviado nem o recebido (é o token).
#
# SIGILO: usuário, senha e token só vivem aqui. Nunca em log, erro, resposta
# (`Response`), inspect, URL ou cURL; mensagem de exceção de rede não sai (só a
# classe). Texto do SI-BNAFAR nunca é guardado: só códigos que casam MSG_CODE.
require "net/http"

module Bnafar
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30
    SERVICES = { "position" => "posicao-estoque-lote", "exit" => "saida-lote" }.freeze
    IBGE_FORMAT = /\A\d{6,7}\z/
    PROTOCOL_FORMAT = /\A\d{1,20}\z/
    MSG_TOKEN = /\bMSG\d{1,4}\b/
    VERBS = { post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete, get: Net::HTTP::Get }.freeze
    NETWORK_ERRORS = [ SocketError, IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
                       Net::ProtocolError, OpenSSL::SSL::SSLError ].freeze

    # status: :accepted | :rejected | :unauthorized | :transient. `items` e
    # `pages` só nas consultas; `error_codes` só os que casam MSG_CODE.
    Response = Data.define(:status, :protocol, :situation, :items, :error_codes, :pages) do
      def inspect = "#<Bnafar::Client::Response #{status}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "status" => status.to_s, "protocol" => protocol, "situation" => situation, "error_codes" => error_codes }
    end

    # Usuário, senha e versão da credencial: lidos dentro da cidade, vivem só aqui.
    Identity = Data.define(:username, :password, :version) do
      def inspect = "#<Bnafar::Client::Identity [FILTERED]>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "filtered" => true }
    end

    CACHE = {}
    CACHE_MUTEX = Mutex.new
    private_constant :CACHE, :CACHE_MUTEX

    def self.reset_cache! = CACHE_MUTEX.synchronize { CACHE.clear }

    # Segundos de validade do token: `expires_in` (s; acima de MS_THRESHOLD, ms)
    # menos TOKEN_MARGIN. 0 quando não sobra nada.
    def self.token_lifetime(expires_in)
      value = Float(expires_in)
      seconds = value > Limits::MS_THRESHOLD ? value / 1000.0 : value
      [ (seconds - Limits::TOKEN_MARGIN).floor, 0 ].max
    rescue ArgumentError, TypeError
      0
    end

    def self.for(city, environment:, settings: Config.for_city(city, environment: environment))
      # interruptores: fora da transação da cidade
      raise Errors::NotConfigured, "SI-BNAFAR não configurado" unless settings

      identity = CityConnection.with(city) do
        credential = IntegrationCredential.find_by(kind: "bnafar", environment: environment)
        credential && Identity.new(username: credential.username, password: credential.password, version: credential.set_at.to_f)
      end
      raise Errors::NotConfigured, "credencial do SI-BNAFAR não cadastrada" unless identity

      new(settings, identity, key: [ city.id, identity.version, environment, settings.simulated ])
    end

    attr_reader :settings
    attr_writer :observer

    def initialize(settings, identity, key:)
      @settings = settings
      @identity = identity
      @key = key
    end

    def simulated? = @settings.simulated

    # Token do jwtauth. `fresh: true` ignora o guardado (o teste da credencial).
    def token!(fresh: false)
      unless fresh
        cached = cached_token
        return cached if cached
      end

      uri = URI(@settings.auth_url)
      request = Net::HTTP::Post.new(uri, "Accept" => "application/json")
      request.basic_auth(@identity.username, @identity.password)
      response = perform(uri, request)
      code = response.code.to_i
      raise Errors::Unauthorized, "bnafar_token_#{code}" if [ 401, 403 ].include?(code)
      raise Errors::Unavailable, "bnafar_token_#{code}" unless code == 200

      body = parse(response.body)
      token = body["access_token"]
      raise Errors::Unavailable, "bnafar_token_invalid" unless token.is_a?(String) && token.present?

      lifetime = self.class.token_lifetime(body["expires_in"])
      CACHE_MUTEX.synchronize { lifetime.positive? ? CACHE[@key] = { token: token, until: monotonic + lifetime } : CACHE.delete(@key) }
      token
    end

    def post_batch(subject:, ibge:, records:) = submit(:post, subject, ibge, records)
    def put_batch(subject:, ibge:, records:) = submit(:put, subject, ibge, records)

    def delete_batch(subject:, ibge:, codes:)
      raw = exchange(:delete, "#{batch_path(subject, ibge)}?#{URI.encode_www_form(codigos: Array(codes).join(','))}")
      interpret(raw) { |body| submission(body) }
    end

    def detail(ibge:, protocol:)
      raw = exchange(:get, "#{protocol_path(ibge, 'detalhar-processamento', protocol)}")
      interpret(raw) { |body| processing(body) }
    end

    def inconsistencies(ibge:, protocol:, page: 0)
      query = URI.encode_www_form(pageNumber: Integer(page), pageSize: Limits::INCONSISTENCY_PAGE)
      raw = exchange(:get, "#{protocol_path(ibge, 'inconsistencias', protocol)}?#{query}")
      interpret(raw) { |body| inconsistency_page(body) }
    end

    def inspect = "#<Bnafar::Client #{simulated? ? 'simulated' : 'real'}>"
    alias_method :to_s, :inspect
    def pretty_print(pp) = pp.text(inspect)
    def as_json(*) = { "simulated" => simulated? }

    private

    def submit(verb, subject, ibge, records)
      raw = exchange(verb, batch_path(subject, ibge), body: JSON.generate(records))
      interpret(raw) { |body| submission(body) }
    end

    def batch_path(subject, ibge)
      service = SERVICES.fetch(subject.to_s) { raise ArgumentError, "assunto desconhecido" }
      "/produto/ibge/#{ibge_of(ibge)}/#{service}"
    end

    def protocol_path(ibge, action, protocol)
      raise ArgumentError, "protocolo inválido" unless protocol.to_s.match?(PROTOCOL_FORMAT)

      "/protocolo/ibge/#{ibge_of(ibge)}/#{action}/#{protocol}"
    end

    def ibge_of(ibge)
      raise ArgumentError, "IBGE inválido" unless ibge.to_s.match?(IBGE_FORMAT)

      ibge.to_s
    end

    # Net::HTTPResponse, ou uma Response já pronta (jwtauth recusado ou fora do ar).
    def exchange(verb, path, body: nil)
      token = cached_token
      from_cache = !token.nil?
      raw = send_once(verb, path, body, token || token!)
      if raw.code.to_i == 401 && from_cache
        # Token guardado pode ter sido revogado: uma repetição com token novo.
        forget_token
        raw = send_once(verb, path, body, token!(fresh: true))
      end
      raw
    rescue Errors::Unauthorized
      forget_token
      build(:unauthorized)
    rescue Errors::Unavailable
      build(:transient)
    end

    def send_once(verb, path, body, token)
      uri = URI("#{@settings.api_url}#{path}")
      request = VERBS.fetch(verb).new(uri, "Authorization" => "jwt #{token}", "Accept" => "application/json")
      if body
        request["Content-Type"] = "application/json"
        request.body = body
      end
      perform(uri, request)
    end

    def interpret(raw)
      return raw if raw.is_a?(Response)

      case raw.code.to_i
      when 200, 201, 202 then yield parse(raw.body)
      when 400, 422 then build(:rejected, error_codes: error_codes_of(parse(raw.body)))
      when 401, 403
        forget_token
        build(:unauthorized)
      else build(:transient) # 5xx e o resto: tenta de novo mais tarde
      end
    end

    def submission(body)
      build(:accepted, protocol: integer_or_nil(body["protocolo"]), situation: body["situacao"]&.to_s)
    end

    def processing(body)
      head = body["protocolo"].is_a?(Hash) ? body["protocolo"] : { "protocolo" => body["protocolo"] }
      items = Array(body["itensProcessados"]).grep(Hash).map do |item|
        { origin_code: item["codigoOrigem"]&.to_s, position: item["posicaoEnvio"], success: item["sucesso"] == true,
          bnafar_code: item["codigoBnafar"], deletion_protocol: item["protocoloExclusao"] }
      end
      build(:accepted, protocol: integer_or_nil(head["protocolo"]), situation: head["situacao"]&.to_s, items: items)
    end

    # Página `{ pageNumber, pageSize, content[...], totalPages }`. Só os códigos
    # MSG; `mensagem` e `valorRejeitado` nunca são lidos. `rejected_items`: os
    # itens distintos recusados do registro (a `posicaoEnvio` da inconsistência;
    # a do registro inteiro vem sem ela).
    def inconsistency_page(body)
      items = Array(body["content"]).grep(Hash).map do |entry|
        issues = Array(entry["inconsistencias"]).grep(Hash)
        { origin_code: entry["codigoOrigem"]&.to_s, position: entry["posicaoEnvio"], codes: msg_codes(issues.map { |i| i["codigo"] }),
          rejected_items: issues.filter_map { |i| i["posicaoEnvio"] }.uniq.size }
      end
      build(:accepted, items: items, error_codes: items.flat_map { |i| i[:codes] }.uniq, pages: integer_or_nil(body["totalPages"]))
    end

    def error_codes_of(body)
      from_text = body["erro-mensagem"].to_s.scan(MSG_TOKEN)
      from_items = Array(body["inconsistencias"]).grep(Hash).map { |i| i["codigo"] }
      msg_codes(from_text + from_items)
    end

    def msg_codes(values) = values.select { |v| v.is_a?(String) && v.match?(Catalog::MSG_CODE) }.uniq

    def build(status, protocol: nil, situation: nil, items: [], error_codes: [], pages: nil)
      Response.new(status: status, protocol: protocol, situation: situation, items: items, error_codes: error_codes, pages: pages)
    end

    def integer_or_nil(value)
      Integer(value.to_s, 10)
    rescue ArgumentError
      nil
    end

    def perform(uri, request)
      options = { use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: OPEN_TIMEOUT,
                  max_retries: 0 }
      response = Net::HTTP.start(uri.host, uri.port, **options) { |http| http.request(request) }
      observe(uri, request, response.code.to_i, response.body)
      response
    rescue *NETWORK_ERRORS => e
      observe(uri, request, nil, nil)
      # A mensagem da exceção traz a URL: só a classe sai.
      raise Errors::Unavailable, "SI-BNAFAR inalcançável (#{e.class.name})"
    end

    def observe(uri, request, status, body)
      return unless @observer

      auth = uri.to_s == @settings.auth_url
      sent = auth || request.body.nil? ? nil : parse_any(request.body)
      @observer.call(method: request.method, url: uri.to_s, body: sent, status: status, response: auth ? nil : body, auth: auth)
    end

    def parse_any(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def cached_token
      cached = CACHE_MUTEX.synchronize { CACHE[@key] }
      cached[:token] if cached && cached[:until] > monotonic
    end

    def forget_token = CACHE_MUTEX.synchronize { CACHE.delete(@key) }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def parse(text)
      parsed = JSON.parse(text.to_s.dup.force_encoding("UTF-8").scrub.presence || "{}")
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
