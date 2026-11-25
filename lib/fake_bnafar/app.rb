# lib/fake_bnafar/app.rb
# SI-BNAFAR SIMULADO (módulo 27b; Manual do SI-BNAFAR v1.25): o jwtauth (Basic
# -> access_token) e os serviços em lote de posição de estoque e saída
# (POST/PUT/DELETE), com Protocolo, detalhar-processamento (situação 2 na 1a
# consulta, 3 ou 4 na seguinte) e inconsistências paginadas. Marcadores de
# teste: lote "RECUSA" -> MSG09; CNES "0000000" -> MSG06; CNPJ
# "00000000000000" -> MSG12; data fora de hoje/ontem -> MSG73; mais de
# `items_limit` itens -> MSG46; todos os itens recusados -> sem codigoBnafar
# (MSG47). A janela de 30 dias (PUT -> MSG16, DELETE -> MSG18) conta de quando
# o ORIGINAL foi ENVIADO (o POST recebido, pelo `clock`), não da aceitação
# (contrato Q25). `failures` imita queda como no FakeSncr::App (Integer =
# status; :refused = conexão recusada). Usado pelas specs (WebMock#to_rack) e
# pelo serviço fake-bnafar do compose de dev (config.ru). Nunca em produção.
# Sem ActiveSupport: roda sozinho no puma. Usuário, senha e token nunca vão
# ao `log` nem ao `inspect`.
require "json"
require "base64"
require "date"
require "securerandom"
require "rack"

module FakeBnafar
  class App
    AUTH_PATH = %r{/jwtauth/auth\z}
    BATCH_PATH = %r{/produto/ibge/(?<ibge>\d+)/(?<service>posicao-estoque-lote|saida-lote)\z}
    PROTOCOL_PATH = %r{/protocolo/ibge/(?<ibge>\d+)/(?<action>detalhar-processamento|inconsistencias)/(?<protocol>\d+)\z}
    SERVICES = { "saida-lote" => "2", "posicao-estoque-lote" => "4" }.freeze # DM06
    OPERATIONS = { "POST" => "1", "PUT" => "2", "DELETE" => "3" }.freeze # DM03
    LOT_LIMIT = 1000
    WINDOW_DAYS = 30
    KEEP = 200
    REFUSED_LOT = "RECUSA".freeze
    UNKNOWN_CNES = "0000000".freeze
    UNKNOWN_CNPJ = "00000000000000".freeze
    FAKE_USER = "00000000000".freeze
    MESSAGES = {
      "MSG06" => "O estabelecimento informado não consta no CNES.",
      "MSG09" => "Para o item o Número do produto é inválido.",
      "MSG12" => "O CNPJ não consta no cadastro da Receita Federal.",
      "MSG16" => "O prazo para inclusão desse registro foi expirado.",
      "MSG18" => "O prazo para exclusão desse registro foi expirado.",
      "MSG19" => "Protocolo não encontrado.",
      "MSG20" => "Registro não encontrado.",
      "MSG38" => "Informe ao menos um parâmetro além do Ente Federativo na requisição.",
      "MSG46" => "Não é permitida a inclusão de mais de 20 itens.",
      "MSG47" => "Todos os itens informados possuem inconsistências, portanto, o registro não foi incluído.",
      "MSG62" => "O limite de itens máximo para processamento em lote é de 1000 registros",
      "MSG73" => "A data de operação deve ser a data atual ou a do dia anterior.",
      "MSG08" => "Informação inválida conforme domínios do campo"
    }.freeze

    # `expires_in` na unidade de `expires_in_unit` (:ms como o SI-BNAFAR, ou :s).
    attr_reader :log, :received
    attr_accessor :clock, :failures, :expires_in, :expires_in_unit, :items_limit

    def initialize(clock: -> { Time.now }, expires_in: 1_800_000, items_limit: 20)
      @clock = clock
      @expires_in = expires_in
      @expires_in_unit = :ms
      @items_limit = items_limit
      @mutex = Mutex.new
      reset!
    end

    def reset!
      @mutex.synchronize do
        @tokens = {}
        @log = []
        @received = []
        @protocols = {}
        @records = {}
        @protocol_seq = 1_000
        @record_seq = 5_000
      end
      @failures = []
    end

    def call(env)
      request = Rack::Request.new(env)
      failure = @mutex.synchronize do
        # Só verbo, caminho e a query: nunca o Authorization (usuário, senha, token).
        @log << [ request.request_method, request.path, {} ]
        @log.shift while @log.size > KEEP
        @failures.shift
      end
      raise Errno::ECONNREFUSED, "fake-bnafar" if failure == :refused
      return error(failure, request, "Erro simulado") if failure.is_a?(Integer)

      route(request)
    end

    def inspect = "#<FakeBnafar::App>"
    alias to_s inspect

    private

    def now = @clock.call

    def route(request)
      verb = request.request_method
      path = request.path
      if verb == "POST" && AUTH_PATH.match?(path) then authenticate(request)
      elsif (m = BATCH_PATH.match(path)) && OPERATIONS.key?(verb) then batch(request, m[:ibge], SERVICES.fetch(m[:service]), verb)
      elsif verb == "GET" && (m = PROTOCOL_PATH.match(path)) then protocol_query(request, m)
      else error(404, request, "Recurso não encontrado")
      end
    end

    # --- jwtauth ---

    def authenticate(request)
      encoded = request.get_header("HTTP_AUTHORIZATION").to_s[/\ABasic (\S+)\z/, 1]
      decoded = encoded && Base64.strict_decode64(encoded) rescue nil # rubocop:disable Style/RescueModifier
      return [ 401, {}, [] ] unless decoded&.include?(":")

      value = SecureRandom.urlsafe_base64(32)
      ttl = @expires_in_unit == :s ? @expires_in : @expires_in / 1000.0
      @mutex.synchronize { @tokens[value] = now + ttl }
      json(200, { access_token: value, scope: "read write", expires_in: @expires_in })
    end

    def authorized?(request)
      value = request.get_header("HTTP_AUTHORIZATION").to_s[/\Ajwt (\S+)\z/, 1]
      expires_at = value && @mutex.synchronize { @tokens[value] }
      !expires_at.nil? && expires_at > now
    end

    def unauthorized(request)
      if request.get_header("HTTP_AUTHORIZATION").to_s.strip.empty?
        [ 401, {}, [] ]
      else
        json(401, { timestamp: stamp, status: 401, error: "Unauthorized", message: "Token inválido ou vencido", path: request.path })
      end
    end

    # --- lotes ---

    def batch(request, ibge, service, verb)
      return unauthorized(request) unless authorized?(request)

      query = query_of(request)
      body = parse(request)
      @mutex.synchronize do
        @received << { method: verb, path: request.path, query: query, body: body }
        @received.shift while @received.size > KEEP
      end
      verb == "DELETE" ? deletion(request, ibge, service, query) : submission(request, ibge, service, verb, body)
    end

    def submission(request, ibge, service, verb, body)
      return bad_request(request, "JsonParse - corpo inválido") unless body.is_a?(Array)
      return bad_request(request, "NotBlank - Não deve estar em branco") if body.empty?
      return bad_request(request, "MSG62 - #{MESSAGES['MSG62']}") if body.size > LOT_LIMIT

      results = body.each_with_index.map { |record, index| evaluate(record, index, service, verb) }
      register(ibge, service, verb, results)
    end

    def evaluate(record, index, service, verb)
      record = {} unless record.is_a?(Hash)
      items = Array(record["itens"]).select { |i| i.is_a?(Hash) }
      origin = record.dig("caracterizacao", "codigoOrigem")
      result = { index: index, origin: origin, items: items.size, errors: [], accepted: false }
      record_errors(record, items, service, verb, result[:errors])
      existing = nil
      if verb == "PUT"
        existing = @mutex.synchronize { @records[record["codigo"]] }
        if existing.nil? || existing[:service] != service || existing[:deleted]
          result[:errors] << issue("MSG20", record["codigo"])
        elsif expired?(existing)
          result[:errors] << issue("MSG16", record["codigo"])
        end
      end
      return result if result[:errors].any?

      items.each_with_index { |item, position| item_errors(item, position, result[:errors]) }
      if result[:errors].map { |e| e[:posicaoEnvio] }.uniq.size >= items.size
        result[:errors] << issue("MSG47", nil)
      else
        result[:code] = existing ? existing[:code] : next_code(service, origin)
        result[:accepted] = true
      end
      result
    end

    def record_errors(record, items, service, verb, errors)
      errors << issue("MSG06", record.dig("estabelecimento", "cnes")) if record.dig("estabelecimento", "cnes") == UNKNOWN_CNES
      errors << issue("MSG46", items.size) if items.size > @items_limit || items.empty?
      date_key = service == "2" ? "dataSaida" : "dataPosicaoEstoque"
      raw = record.dig("caracterizacao", date_key)
      date = (Date.iso8601(raw.to_s) rescue nil) # rubocop:disable Style/RescueModifier
      if date.nil? then errors << issue("MSG08", raw)
      elsif verb == "POST" && (date < today - 1 || date > today) then errors << issue("MSG73", raw) # a alteração vale pelo prazo (MSG16)
      end
    end

    def item_errors(item, position, errors)
      origin = item["codigoOrigem"]
      errors << issue("MSG09", item["lote"], position, origin) if item["lote"] == REFUSED_LOT
      errors << issue("MSG12", item["cnpjFabricante"], position, origin) if item["cnpjFabricante"] == UNKNOWN_CNPJ
    end

    def issue(code, rejected, position = nil, origin = nil)
      { codigo: code, mensagem: MESSAGES.fetch(code), valorRejeitado: rejected.nil? ? nil : rejected.to_s, posicaoEnvio: position, codigoOrigem: origin }
    end

    def next_code(service, origin)
      @mutex.synchronize do
        code = (@record_seq += 1)
        @records[code] = { code: code, service: service, origin: origin, sent_at: now, deleted: false, protocol: nil }
        code
      end
    end

    def register(ibge, service, verb, results)
      protocol = new_protocol(ibge, service, verb, results)
      if verb == "POST"
        @mutex.synchronize { results.select { |r| r[:accepted] }.each { |r| @records[r[:code]][:protocol] = protocol[:protocolo] } }
      end
      json(200, summary(protocol))
    end

    # --- exclusão ---

    def deletion(request, ibge, service, query)
      codes = Array(query["codigos"]).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?).uniq
      protocol = query["protocolo"].to_s.strip
      return bad_request(request, "MSG38 - #{MESSAGES['MSG38']}") if codes.empty? && protocol.empty?

      unless protocol.empty?
        original = @mutex.synchronize { @protocols[protocol.to_i] }
        return error(400, request, "MSG19 - #{MESSAGES['MSG19']}") unless original

        codes |= @mutex.synchronize { @records.values.select { |r| r[:protocol] == original[:protocolo] }.map { |r| r[:code].to_s } }
      end
      results = codes.each_with_index.map { |raw, index| delete_one(raw, index, service) }
      register(ibge, service, "DELETE", results)
    end

    def delete_one(raw, index, service)
      record = @mutex.synchronize { @records[raw.to_i] }
      result = { index: index, origin: record&.dig(:origin), items: 1, errors: [], accepted: false }
      if record.nil? || record[:service] != service || record[:deleted]
        result[:errors] << issue("MSG20", raw)
      elsif expired?(record)
        result[:errors] << issue("MSG18", raw)
      else
        result[:accepted] = true
        result[:code] = record[:code]
        result[:deleted_protocol] = record[:protocol]
        @mutex.synchronize { record[:deleted] = true }
      end
      result
    end

    # O prazo conta do ENVIO do original (Q25), não da aceitação.
    def expired?(record) = now - record[:sent_at] > WINDOW_DAYS * 86_400

    # --- consultas ---

    def new_protocol(ibge, service, verb, results)
      @mutex.synchronize do
        number = (@protocol_seq += 1)
        @protocols[number] = { protocolo: number, ibge: ibge, service: service, operation: OPERATIONS.fetch(verb), sent_at: now,
                               results: results, polls: 0 }
      end
    end

    def protocol_query(request, match)
      return unauthorized(request) unless authorized?(request)

      protocol = @mutex.synchronize { @protocols[match[:protocol].to_i] }
      return error(404, request, "MSG19 - #{MESSAGES['MSG19']}") unless protocol

      match[:action] == "detalhar-processamento" ? detail(protocol) : inconsistencies(request, protocol)
    end

    def summary(protocol, status = "1")
      { protocolo: protocol[:protocolo], situacao: status, codigoIbge: protocol[:ibge], dataProtocolo: stamp(protocol[:sent_at]),
        tipoOperacao: protocol[:operation], tipoServico: protocol[:service], usuarioEnvio: FAKE_USER }
    end

    def detail(protocol)
      polls = @mutex.synchronize { protocol[:polls] += 1 }
      results = protocol[:results]
      if polls == 1
        body = { protocolo: summary(protocol, "2"),
                 processamento: { incioProcessamento: stamp, quantidadeItensTotal: total_items(results), quantidadeItensSucesso: 0, quantidadeItensInconsistente: 0 } }
        return json(200, body)
      end

      failed = results.count { |r| r[:errors].any? }
      status = failed.zero? ? "3" : "4"
      json(200, { protocolo: summary(protocol, status),
                  processamento: { incioProcessamento: stamp(protocol[:sent_at]), fimProcessamento: stamp, quantidadeItensTotal: total_items(results),
                                   quantidadeItensSucesso: results.count { |r| r[:errors].empty? }, quantidadeItensInconsistente: failed },
                  itensProcessados: results.map { |r| processed(r) } })
    end

    def processed(result)
      item = { codigoOrigem: result[:origin], posicaoEnvio: result[:index], sucesso: result[:errors].empty? }
      item[:codigoBnafar] = result[:code] if result[:accepted]
      item[:protocoloExclusao] = result[:deleted_protocol] if result[:deleted_protocol]
      item
    end

    def total_items(results) = results.sum { |r| r[:items] }

    def inconsistencies(request, protocol)
      query = query_of(request)
      number = [ query["pageNumber"].to_i, 0 ].max
      size = query["pageSize"].to_i.positive? ? query["pageSize"].to_i : 20
      entries = protocol[:polls] >= 2 ? protocol[:results].select { |r| r[:errors].any? } : []
      content = entries.drop(number * size).first(size).map do |r|
        { codigoOrigem: r[:origin], posicaoEnvio: r[:index], inconsistencias: r[:errors] }
      end
      json(200, { pageNumber: number, pageSize: size, content: content, numberOfElements: content.size,
                  totalElements: entries.size, totalPages: (entries.size / size.to_f).ceil })
    end

    # --- util ---

    def today = now.to_date

    def stamp(time = now) = time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%L")

    def query_of(request) = Rack::Utils.parse_query(request.query_string.to_s)

    def parse(request)
      JSON.parse(request.body&.read.to_s)
    rescue JSON::ParserError
      nil
    end

    def bad_request(request, text) = error(400, request, text)

    def error(status, request, text)
      json(status, { "http-status" => status, "recurso-api" => "#{request.request_method}:#{request.path}", "erro-mensagem" => text })
    end

    def json(status, body) = [ status, { "content-type" => "application/json; charset=utf-8" }, [ JSON.generate(body) ] ]
  end
end
