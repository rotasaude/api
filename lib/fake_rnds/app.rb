# lib/fake_rnds/app.rb
# RNDS SIMULADA (ADR 0047; módulo 29, Desvio 14): o EHR-AUTH (GET /api/token)
# e o EHR-Services (POST /api/fhir/r4/Bundle) num só servidor, em http e SEM
# mTLS — o certificado de teste da semente basta, porque nada aqui o confere.
# O Bundle aceito volta 201 com Location; o marcador `lotNumber == "RECUSA"`
# devolve 422 com um OperationOutcome (que cita um CPF, para provar a limpeza
# do cliente) e `"TIMEOUT"` segura a resposta além do prazo do cliente.
# `failures` imita queda como no FakeSncr::App (Integer = status 5xx/4xx;
# :refused = conexão recusada). Usado pelas specs (WebMock#to_rack) e pelo
# serviço fake-rnds do compose de dev (config.ru). Nunca em produção. Sem
# ActiveSupport: roda sozinho no puma.
require "json"
require "net/http"
require "securerandom"
require "rack"

module FakeRnds
  class App
    TOKEN_TTL = 1800
    BUNDLE_PATH = "/api/fhir/r4/Bundle".freeze
    TOKEN_PATH = "/api/token".freeze
    REFUSED_LOT = "RECUSA".freeze
    TIMEOUT_LOT = "TIMEOUT".freeze
    REFUSED_TEXT = "Lote inválido para o CPF 12345678901".freeze
    LOG_HEADERS = { "HTTP_AUTHORIZATION" => "authorization", "HTTP_X_AUTHORIZATION_SERVER" => "x-authorization-server" }.freeze
    KEEP = 200

    attr_reader :log, :accepted
    attr_accessor :clock, :failures, :timeout_delay

    def initialize(clock: -> { Time.now }, timeout_delay: 25)
      @clock = clock
      @timeout_delay = timeout_delay
      @mutex = Mutex.new
      reset!
    end

    def reset!
      @mutex.synchronize do
        @tokens = {}
        @log = []
        @accepted = []
      end
      @failures = []
    end

    def issued_tokens = @mutex.synchronize { @tokens.keys }

    def call(env)
      request = Rack::Request.new(env)
      failure = @mutex.synchronize do
        headers = LOG_HEADERS.filter_map { |key, name| [ name, request.get_header(key) ] if request.get_header(key) }.to_h
        @log << [ request.request_method, request.path, headers ]
        @log.shift while @log.size > KEEP
        @failures.shift
      end
      raise Errno::ECONNREFUSED, "fake-rnds" if failure == :refused
      return outcome(failure, "Erro simulado") if failure.is_a?(Integer)

      route(request)
    end

    def inspect = "#<FakeRnds::App>"

    private

    def now = @clock.call

    def route(request)
      verb = request.request_method
      if verb == "GET" && request.path.end_with?(TOKEN_PATH) then token
      elsif verb == "POST" && request.path.end_with?(BUNDLE_PATH) then bundle(request)
      else outcome(404, "Recurso não encontrado")
      end
    end

    def token
      value = SecureRandom.urlsafe_base64(32)
      @mutex.synchronize { @tokens[value] = now + TOKEN_TTL }
      json(200, { access_token: value, scope: "rnds_simulada", expires_in: TOKEN_TTL, token_type: "jwt" })
    end

    def bundle(request)
      bearer = request.get_header("HTTP_X_AUTHORIZATION_SERVER").to_s.delete_prefix("Bearer ")
      expires_at = @mutex.synchronize { @tokens[bearer] }
      return outcome(401, "Token ausente, inválido ou vencido") unless expires_at && expires_at > now
      return outcome(422, "Profissional (CNS) não informado") if request.get_header("HTTP_AUTHORIZATION").to_s.strip.empty?

      body = parse(request)
      return outcome(400, "Bundle inválido") unless body["resourceType"] == "Bundle" && body["entry"].is_a?(Array)

      lots = body["entry"].filter_map { |entry| entry.is_a?(Hash) && entry["resource"].is_a?(Hash) ? entry.dig("resource", "lotNumber") : nil }
      if lots.include?(TIMEOUT_LOT)
        sleep(@timeout_delay) if @timeout_delay.to_f.positive?
        raise Net::ReadTimeout, "fake-rnds"
      end
      return outcome(422, REFUSED_TEXT) if lots.include?(REFUSED_LOT)

      id = SecureRandom.uuid
      @mutex.synchronize do
        @accepted << { id: id, bundle: body }
        @accepted.shift while @accepted.size > KEEP
      end
      [ 201, { "content-type" => "application/fhir+json", "location" => "#{request.base_url}#{request.script_name}#{request.path}/#{id}" }, [] ]
    end

    def outcome(status, text)
      json(status, { resourceType: "OperationOutcome", issue: [ { severity: "error", code: status >= 500 ? "exception" : "processing", diagnostics: text } ] })
    end

    def parse(request)
      parsed = JSON.parse(request.body.read.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def json(status, body) = [ status, { "content-type" => "application/json; charset=utf-8" }, [ JSON.generate(body) ] ]
  end
end
