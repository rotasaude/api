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
      def inspect = "#<Ledi::PecClient::Session cookie=[FILTERED]>"
      alias_method :to_s, :inspect

      def pretty_print(q) = q.text(inspect)
    end

    LOGIN_PATH = "/api/recebimento/login".freeze
    TIMEOUT = 10
    NETWORK_ERRORS = [ SocketError, IOError, EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                       Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError ].freeze

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

    def inspect = "#<Ledi::PecClient #{@base_url}>"

    private

    def post(path, body, content_type, headers = {})
      uri = URI.parse("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = content_type
      headers.each { |name, value| request[name] = value }
      request.body = body
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout) do |http|
        http.request(request)
      end
    rescue *NETWORK_ERRORS => e
      raise Unreachable, "PEC inalcançável (#{e.class.name})"
    end

    def session_cookie(response)
      Array(response.get_fields("set-cookie")).map { |c| c.split(";").first.to_s.strip }
                                              .find { |c| c.start_with?("JSESSIONID=") && c.length > 11 }
    end
  end
end
