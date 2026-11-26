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
#
# Regulação (26c): o Bundle RIRA (Composition com o perfil BRRegulacaoAssistencial
# ou type RA) forma uma cadeia por `Bundle.identifier.value`: o POST com
# `Composition.relatesTo` (replaces) troca o anterior para `entered-in-error`;
# substituir o já substituído -> 422 (EDS-MSG009); `DELETE` de final -> 204, senão
# 422 (EHR-ERR825); `GET /api/identifier` lista a cadeia. Marcadores no
# `identifier.value`: RECUSA (422 EHR-ERR999), TIMEOUT (grava e estoura) e DUPLICADO
# (no 1º POST grava dois finais sem relação e estoura). O Bundle da vacina segue
# pelo `lotNumber`, sem cadeia.
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
    IDENTIFIER_PATH = "/api/identifier".freeze
    # Sufixo do perfil canônico da Composition (config/rnds/rira_1_0.yml, conferido
    # em spec): o fake não carrega o Rails, então não lê o YAML.
    RIRA_PROFILE_SUFFIX = "/StructureDefinition/BRRegulacaoAssistencial".freeze
    RIRA_TYPE_CODE = "RA".freeze
    DUPLICATE_MARK = "DUPLICADO".freeze
    FINAL = "final".freeze
    VOID = "entered-in-error".freeze
    RIRA_REFUSED_TEXT = "(EHR-ERR999) Documento recusado pelo simulado".freeze
    FAKE_CNS = "700000000000005".freeze
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
        @documents = []
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
      elsif verb == "GET" && request.path.end_with?(IDENTIFIER_PATH) then identifier(request)
      elsif verb == "DELETE" && (id = request.path[%r{#{Regexp.escape(BUNDLE_PATH)}/([\w.-]+)\z}, 1]) then delete(request, id)
      else outcome(404, "Recurso não encontrado")
      end
    end

    def token
      value = SecureRandom.urlsafe_base64(32)
      @mutex.synchronize { @tokens[value] = now + TOKEN_TTL }
      json(200, { access_token: value, scope: "rnds_simulada", expires_in: TOKEN_TTL, token_type: "jwt" })
    end

    # nil quando o token e o CNS servem; senão a resposta de recusa.
    def unauthorized(request)
      bearer = request.get_header("HTTP_X_AUTHORIZATION_SERVER").to_s.delete_prefix("Bearer ")
      expires_at = @mutex.synchronize { @tokens[bearer] }
      return outcome(401, "Token ausente, inválido ou vencido") unless expires_at && expires_at > now
      return outcome(422, "Profissional (CNS) não informado") if request.get_header("HTTP_AUTHORIZATION").to_s.strip.empty?

      nil
    end

    def bundle(request)
      refusal = unauthorized(request)
      return refusal if refusal

      body = parse(request)
      return outcome(400, "Bundle inválido") unless body["resourceType"] == "Bundle" && body["entry"].is_a?(Array)
      return rira_bundle(request, body) if rira?(body)

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

    def rira?(body)
      body["entry"].any? do |entry|
        resource = entry.is_a?(Hash) ? entry["resource"] : nil
        next false unless resource.is_a?(Hash) && resource["resourceType"] == "Composition"

        Array(resource.dig("meta", "profile")).any? { |url| url.to_s.end_with?(RIRA_PROFILE_SUFFIX) } ||
          Array(resource.dig("type", "coding")).any? { |coding| coding.is_a?(Hash) && coding["code"] == RIRA_TYPE_CODE }
      end
    end

    # Cadeia por Bundle.identifier.value (só o RIRA). `relatesTo` com `targetReference`
    # (replaces); o da vacina (`targetIdentifier`) nunca passa por aqui.
    def rira_bundle(request, body)
      system = body.dig("identifier", "system").to_s
      value = body.dig("identifier", "value").to_s
      return outcome(400, "Bundle sem identifier.value") if value.empty?
      return outcome(422, RIRA_REFUSED_TEXT) if value.include?(REFUSED_LOT)

      target = replaces_of(body)
      duplicate = value.include?(DUPLICATE_MARK) && @mutex.synchronize { @documents.none? { |doc| doc[:value] == value } }
      id = SecureRandom.uuid
      failure = @mutex.synchronize do
        old = target && @documents.find { |doc| doc[:id] == target }
        if old && old[:status] == VOID
          "(EDS-MSG009) O documento #{target} já foi substituído."
        else
          old[:status] = VOID if old
          store(id, system, value, body, target)
          store(SecureRandom.uuid, system, value, body, nil) if duplicate
          nil
        end
      end
      return outcome(422, failure) if failure

      if duplicate || value.include?(TIMEOUT_LOT)
        sleep(@timeout_delay) if @timeout_delay.to_f.positive?
        raise Net::ReadTimeout, "fake-rnds"
      end
      [ 201, { "content-type" => "application/fhir+json", "location" => "#{request.base_url}#{request.script_name}#{request.path}/#{id}" }, [] ]
    end

    # Já dentro do mutex.
    def store(id, system, value, body, replaces)
      @documents << { id: id, system: system, value: value, status: FINAL, replaces: replaces, date: now.iso8601 }
      @accepted << { id: id, bundle: body }
      @accepted.shift while @accepted.size > KEEP
    end

    def replaces_of(body)
      composition = body["entry"].filter_map { |entry| entry["resource"] if entry.is_a?(Hash) && entry["resource"].is_a?(Hash) }.find { |resource| resource["resourceType"] == "Composition" }
      relation = Array(composition && composition["relatesTo"]).find { |item| item.is_a?(Hash) && item["code"] == "replaces" }
      relation&.dig("targetReference", "reference").to_s.delete_prefix("Composition/").then { |ref| ref.empty? ? nil : ref }
    end

    # GET /api/identifier?system=&value=&docType=: a cadeia do identificador (o `docType` não filtra).
    def identifier(request)
      refusal = unauthorized(request)
      return refusal if refusal

      system = request.params["system"].to_s
      value = request.params["value"].to_s
      docs = @mutex.synchronize { @documents.select { |doc| doc[:value] == value && (system.empty? || doc[:system] == system) }.map(&:dup) }
      json(200, docs.map { |doc| { id: doc[:id], cns: FAKE_CNS, date: doc[:date], relatesTo: doc[:replaces], status: doc[:status] } })
    end

    def delete(request, id)
      refusal = unauthorized(request)
      return refusal if refusal

      result = @mutex.synchronize do
        doc = @documents.find { |item| item[:id] == id }
        if doc.nil? then :missing
        elsif doc[:status] == FINAL then doc[:status] = VOID and :ok
        else :not_final
        end
      end
      case result
      when :ok then [ 204, {}, [] ]
      when :missing then outcome(404, "Documento não encontrado")
      else outcome(422, "(EHR-ERR825) O documento #{id} não está no estado final.")
      end
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
