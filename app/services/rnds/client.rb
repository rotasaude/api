# Transporte da RNDS (módulo 29, ADR 0047, Desvio 14). `GET {auth_url}/api/token`
# com mTLS (o PKCS#12 A1 da credencial `rnds` da cidade) devolve o token; o
# Bundle vai em `POST {ehr_url}/api/fhir/r4/Bundle` com
# `X-Authorization-Server: Bearer <token>` e `Authorization: <CNS do vacinador>`.
# O simulado (FakeRnds::App) fala http e dispensa o certificado. O token fica
# em memória do processo, por cidade e versão da credencial, 25 min; um 401/403
# o descarta. Certificado, senha, token, CNS e payload NUNCA em log, erro,
# resposta ou inspect; mensagem de exceção de rede não sai (só a classe).
require "net/http"

module Rnds
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    TOKEN_TTL = 25 * 60
    TOKEN_PATH = "/api/token".freeze
    BUNDLE_PATH = "/api/fhir/r4/Bundle".freeze
    CNS_FORMAT = /\A\d{15}\z/
    ID_FORMAT = /\A[\w.-]{1,100}\z/
    # Alertas TLS de certificado de cliente recusado (heurística pela mensagem do
    # SSLError, que só classifica e nunca sai); gate de go-live: conferir contra a RNDS real.
    CERTIFICATE_ALERT = /bad certificate|unsupported certificate|certificate (unknown|revoked|expired|required)|unknown ca|alert unknown_ca/i
    NETWORK_ERRORS = [ SocketError, IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
                       Net::ProtocolError, OpenSSL::SSL::SSLError ].freeze

    Response = Data.define(:status, :rnds_id, :error) do
      def inspect = "#<Rnds::Client::Response #{status}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    # PFX, senha e versão da credencial: lidos dentro da cidade, vivem só aqui.
    Identity = Data.define(:pfx, :password, :version) do
      def inspect = "#<Rnds::Client::Identity [FILTERED]>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    CACHE = {}
    CACHE_MUTEX = Mutex.new
    private_constant :CACHE, :CACHE_MUTEX

    def self.reset_cache! = CACHE_MUTEX.synchronize { CACHE.clear }

    def self.for(city, env: Rails.env)
      settings = Config.for_city(city, env: env) # interruptores: fora da transação da cidade
      raise Errors::NotConfigured, "RNDS não configurada" unless settings

      identity = CityConnection.with(city) do
        credential = IntegrationCredential.find_by(kind: "rnds")
        credential && Identity.new(pfx: credential.pfx_bytes, password: credential.pfx_password, version: credential.set_at.to_f)
      end
      raise Errors::NotConfigured, "credencial da RNDS não cadastrada" unless identity&.pfx

      new(settings, identity, key: [ city.id, identity.version, settings.simulated ])
    end

    attr_reader :settings

    def initialize(settings, identity, key:)
      @settings = settings
      @identity = identity
      @key = key
    end

    def simulated? = @settings.simulated

    # Token do EHR-AUTH. `fresh: true` ignora o guardado (o teste da credencial).
    def token!(fresh: false)
      unless fresh
        cached = cached_token
        return cached if cached
      end

      response = perform(URI("#{@settings.auth_url}#{TOKEN_PATH}"), Net::HTTP::Get.new(URI("#{@settings.auth_url}#{TOKEN_PATH}"), "Accept" => "application/json"))
      code = response.code.to_i
      raise Errors::Unauthorized, "rnds_token_#{code}" if [ 401, 403 ].include?(code)
      raise Errors::Unavailable, "rnds_token_#{code}" unless code == 200

      token = parse(response.body)["access_token"]
      raise Errors::Unavailable, "rnds_token_invalid" unless token.is_a?(String) && token.present?

      CACHE_MUTEX.synchronize { CACHE[@key] = { token: token, until: monotonic + TOKEN_TTL } }
      token
    end

    # -> Response(status: :accepted | :rejected | :unauthorized | :transient, rnds_id:, error:)
    def post_bundle(bundle, practitioner_cns:)
      raise ArgumentError, "CNS do profissional inválido" unless practitioner_cns.to_s.match?(CNS_FORMAT)

      token = cached_token
      from_cache = !token.nil?
      response = deliver(bundle, practitioner_cns, token || token!)
      if response.status == :unauthorized && from_cache
        # Token guardado pode ter sido revogado antes dos 25 min: uma repetição com token novo
        # antes de culpar o certificado.
        response = deliver(bundle, practitioner_cns, token!)
      end
      response
    rescue Errors::Unauthorized
      forget_token
      Response.new(status: :unauthorized, rnds_id: nil, error: nil)
    rescue Errors::Unavailable
      Response.new(status: :transient, rnds_id: nil, error: nil)
    end

    def inspect = "#<Rnds::Client #{simulated? ? 'simulated' : 'real'}>"
    alias_method :to_s, :inspect
    def pretty_print(pp) = pp.text(inspect)

    private

    def deliver(bundle, practitioner_cns, token)
      uri = URI("#{@settings.ehr_url}#{BUNDLE_PATH}")
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/fhir+json", "Accept" => "application/fhir+json",
                                         "X-Authorization-Server" => "Bearer #{token}", "Authorization" => practitioner_cns.to_s)
      request.body = JSON.generate(bundle)
      interpret(perform(uri, request))
    end

    def cached_token
      cached = CACHE_MUTEX.synchronize { CACHE[@key] }
      cached[:token] if cached && cached[:until] > monotonic
    end

    def interpret(response)
      code = response.code.to_i
      case code
      when 200, 201
        Response.new(status: :accepted, rnds_id: id_from(response["Location"]), error: nil)
      when 400, 422
        Response.new(status: :rejected, rnds_id: nil, error: diagnostics(response.body))
      when 401, 403
        forget_token
        Response.new(status: :unauthorized, rnds_id: nil, error: nil)
      else
        Response.new(status: :transient, rnds_id: nil, error: nil) # 5xx e o resto: tenta de novo mais tarde
      end
    end

    def perform(uri, request)
      options = { use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: OPEN_TIMEOUT,
                  max_retries: 0 }
      options.merge!(mtls) if options[:use_ssl] && !simulated?
      Net::HTTP.start(uri.host, uri.port, **options) { |http| http.request(request) }
    rescue OpenSSL::SSL::SSLError => e
      # A mensagem só classifica; nunca vai para o erro.
      raise Errors::Unauthorized, "certificado da RNDS recusado" if CERTIFICATE_ALERT.match?(e.message)

      raise Errors::Unavailable, "RNDS inalcançável (#{e.class.name})"
    rescue *NETWORK_ERRORS => e
      raise Errors::Unavailable, "RNDS inalcançável (#{e.class.name})"
    end

    def mtls
      pkcs12 = OpenSSL::PKCS12.new(@identity.pfx, @identity.password)
      { cert: pkcs12.certificate, key: pkcs12.key }
    rescue OpenSSL::OpenSSLError
      raise Errors::Unauthorized, "certificado da RNDS ilegível"
    end

    def diagnostics(body)
      issues = Array(parse(body)["issue"]).filter_map { |issue| issue["diagnostics"] if issue.is_a?(Hash) }
      Errors.sanitize(issues.join("; ")).presence || "A RNDS recusou o envio"
    end

    def id_from(location)
      id = location.to_s.split("?").first.to_s.split("/").last
      id if id&.match?(ID_FORMAT)
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
