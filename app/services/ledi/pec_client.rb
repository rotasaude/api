require "net/http"

# Cliente da API de recebimento do PEC da cidade (ADR 0028; spec 2026-10-05 §1;
# pesquisa frente 1): POST /api/recebimento/login (usuario/senha em JSON →
# cookie JSESSIONID). Único lugar que conhece o formato do login — a prova
# técnica do exportador confirma, e o envio da ficha entra aqui no plano dele.
# Nenhuma mensagem de erro carrega senha, cookie ou corpo da resposta.
module Ledi
  class PecClient
    class Error < StandardError; end
    class Unauthorized < Error; end
    class Unreachable < Error; end

    class Failed < Error
      attr_reader :status

      def initialize(status)
        @status = status
        super("o PEC respondeu #{status}")
      end
    end

    # O cookie é a sessão autenticada no PEC: nunca em inspect, to_s nem pp
    # (log, mensagem de exceção, console).
    Session = Data.define(:cookie) do
      # POST do binário .esus (DadoTransporteThrift em TBinaryProtocol), como no
    # exemplo oficial ExemploEnvioApi.java: multipart, campo `ficha`, nome do
    # arquivo = uuidDadoSerializado + ".esus". Nunca loga corpo nem cookie.
    def deliver(cookie:, filename:, bytes:)
      boundary = "rotasaude#{SecureRandom.hex(12)}"
      body = "--#{boundary}\r\n" \
             "Content-Disposition: form-data; name=\"ficha\"; filename=\"#{filename}\"\r\n" \
             "Content-Type: application/octet-stream\r\n\r\n".b + bytes.b + "\r\n--#{boundary}--\r\n".b
      response = post(DELIVER_PATH, body, "multipart/form-data; boundary=#{boundary}", "Cookie" => cookie)
      Reply.new(status: response.code.to_i, body: response.body.to_s)
    end

    def inspect = "#<Ledi::PecClient::Session cookie=[FILTERED]>"
      alias_method :to_s, :inspect

      def pretty_print(q) = q.text(inspect)
    end

    # Resposta crua do recebimento (o que significa fica com Ledi::Outcome).
    Reply = Data.define(:status, :body)

    LOGIN_PATH = "/api/recebimento/login".freeze
    DELIVER_PATH = "/api/v1/recebimento/ficha".freeze
    TIMEOUT = 10
    NETWORK_ERRORS = [ SocketError, IOError, EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                       Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::EPIPE,
                       Errno::ENETUNREACH, OpenSSL::SSL::SSLError ].freeze

    def initialize(base_url:, username:, password:, timeout: TIMEOUT)
      @base_url = base_url.to_s.chomp("/")
      @username = username
      @password = password
      @timeout = timeout
    end

    def login
      response = post(LOGIN_PATH, { usuario: @username, senha: @password }.to_json, "application/json")
      case response.code.to_i
      when 200..299
        cookie = session_cookie(response)
        raise Failed.new(response.code.to_i) unless cookie

        Session.new(cookie: cookie)
      when 401, 403 then raise Unauthorized, "o PEC recusou usuário ou senha"
      else raise Failed.new(response.code.to_i)
      end
    end

    # POST do binário .esus (DadoTransporteThrift em TBinaryProtocol), como no
    # exemplo oficial ExemploEnvioApi.java: multipart, campo `ficha`, nome do
    # arquivo = uuidDadoSerializado + ".esus". Nunca loga corpo nem cookie.
    def deliver(cookie:, filename:, bytes:)
      boundary = "rotasaude#{SecureRandom.hex(12)}"
      body = "--#{boundary}\r\n" \
             "Content-Disposition: form-data; name=\"ficha\"; filename=\"#{filename}\"\r\n" \
             "Content-Type: application/octet-stream\r\n\r\n".b + bytes.b + "\r\n--#{boundary}--\r\n".b
      response = post(DELIVER_PATH, body, "multipart/form-data; boundary=#{boundary}", "Cookie" => cookie)
      Reply.new(status: response.code.to_i, body: response.body.to_s)
    end

    def inspect = "#<Ledi::PecClient #{@base_url}>"

    private

    def post(path, body, content_type, headers = {})
      uri = URI.parse("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = content_type
      headers.each { |name, value| request[name] = value }
      request.body = body
      raise Unreachable, "URL do PEC inválida" if uri.host.blank?

      Net::HTTP.start(uri.host, uri.port, **http_options(uri)) do |http|
        http.request(request)
      end
    rescue URI::InvalidURIError
      # A mensagem original da URI::InvalidURIError carrega a URL: não repassa.
      raise Unreachable, "URL do PEC inválida"
    rescue *NETWORK_ERRORS => e
      raise Unreachable, "PEC inalcançável (#{e.class.name})"
    end

    # CA local só em development/test (PEC da prova técnica, certificado da CA de
    # deploy/development/pec/local/ca.pem; docs/operacao/pec-local-dev.md).
    def http_options(uri)
      options = { use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout }
      ca_file = ENV["LEDI_PEC_CA_FILE"]
      options[:ca_file] = ca_file if ca_file.present? && Rails.env.local?
      options
    end

    def session_cookie(response)
      Array(response.get_fields("set-cookie")).map { |c| c.split(";").first.to_s.strip }
                                              .find { |c| c.start_with?("JSESSIONID=") && c.length > 11 }
    end
  end
end
