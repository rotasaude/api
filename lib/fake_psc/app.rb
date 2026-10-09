# lib/fake_psc/app.rb
# PSC falso da API v0 do ITI (DOC-ICP-17.01): user-discovery, authorize, token
# (PKCE S256), certificate-discovery e signature (RAW), com e-CPF de teste da
# AC do signer de dev (FakePsc::Pki; as LCRs quem serve é o signer). Usado pelas specs (WebMock#to_rack) e pelo serviço fake-psc do compose
# de dev (lib/fake_psc/config.ru). Nunca carregado em produção. Sem
# ActiveSupport: roda sozinho no puma.
require "json"
require "openssl"
require "securerandom"
require "base64"
require "digest"
require "uri"
require "rack"
require_relative "pki"

module FakePsc
  class App
    CLIENT_ID = "rota-dev".freeze
    CLIENT_SECRET = "dev-secret".freeze
    SHA256_OID = "2.16.840.1.101.3.4.2.1".freeze
    SCOPES = %w[single_signature multi_signature signature_session authentication_session].freeze
    ONE_SHOT_TTL = 300

    attr_reader :pki, :log
    attr_accessor :absent_cpfs, :failures, :max_lifetime, :forced_lifetime, :before_sign, :certificate_overrides

    def initialize(pki:, client_id: CLIENT_ID, client_secret: CLIENT_SECRET)
      @pki = pki
      @client_id = client_id
      @client_secret = client_secret
      @mutex = Mutex.new
      reset!
    end

    def reset!
      @mutex.synchronize do
        @pending = {}
        @codes = {}
        @tokens = {}
        @log = []
      end
      @absent_cpfs = []
      @failures = []
      @certificate_overrides = {}
      @max_lifetime = 7 * 86_400
      @forced_lifetime = nil
      @before_sign = nil
    end

    # — Ganchos de teste (o "celular" do titular e o estado do PSC) —

    def decide!(state, approve: true)
      id = @mutex.synchronize { @pending.find { |_id, pending| pending[:state] == state }&.first }
      raise ArgumentError, "autorização desconhecida" unless id

      decision(id, approve)
    end

    def approve!(state)
      URI.decode_www_form(URI(decide!(state)).query).to_h.fetch("code")
    end

    def leaf(cpf) = @certificate_overrides[cpf] || @pki.leaf_for(cpf)
    def token_for!(cpf:, scope: "signature_session", ttl: 3600) = issue_token(cpf, scope, ttl)
    def expire_tokens! = @mutex.synchronize { @tokens.each_value { |token| token[:expires_at] = Time.now - 1 } }
    def issued_tokens = @mutex.synchronize { @tokens.keys }

    def call(env)
      request = Rack::Request.new(env)
      failure = @mutex.synchronize do
        @log << [ request.request_method, request.path ]
        @failures.shift
      end
      raise Errno::ECONNREFUSED, "fake-psc" if failure == :refused
      return json(failure, { error: "server_error" }) if failure.is_a?(Integer)

      route(request)
    rescue ArgumentError
      json(400, { error: "invalid_request" })
    end

    def inspect = "#<FakePsc::App>"

    private

    def route(request)
      case [ request.request_method, request.path ]
      in [ "POST", "/v0/oauth/user-discovery" ] then user_discovery(request)
      in [ "GET", "/v0/oauth/authorize" ] then authorize(request)
      in [ "GET", "/v0/oauth/authorize/decision" ]
        [ 302, { "location" => decision(request.params["id"].to_s, request.params["approve"] == "1") }, [] ]
      in [ "POST", "/v0/oauth/token" ] then token(request)
      in [ "GET", "/v0/oauth/certificate-discovery" ] then certificates(request)
      in [ "POST", "/v0/oauth/signature" ] then signature(request)
      else json(404, { error: "not_found" })
      end
    end

    def user_discovery(request)
      body = parse_json(request)
      return json(401, { error: "invalid_client" }) unless client?(body["client_id"], body["client_secret"])

      cpf = body["val_cpf_cnpj"].to_s
      found = body["user_cpf_cnpj"] == "CPF" && cpf.match?(/\A\d{11}\z/) && !@absent_cpfs.include?(cpf)
      json(200, found ? { status: "S", slots: [ { slot_alias: cpf, label: "Certificado de teste" } ] } : { status: "N", slots: [] })
    end

    def authorize(request)
      params = request.params
      valid = params["response_type"] == "code" && params["client_id"] == @client_id &&
              params["code_challenge_method"] == "S256" && SCOPES.include?(params["scope"]) &&
              params["code_challenge"].to_s.size >= 43 && params["redirect_uri"].to_s.start_with?("http") &&
              params["login_hint"].to_s.match?(/\A\d{11}\z/)
      return json(400, { error: "invalid_request" }) unless valid

      id = SecureRandom.hex(8)
      @mutex.synchronize do
        @pending[id] = { state: params["state"], redirect_uri: params["redirect_uri"], scope: params["scope"],
                         challenge: params["code_challenge"], cpf: params["login_hint"],
                         lifetime: params["lifetime"]&.to_i }
      end
      [ 200, { "content-type" => "text/html; charset=utf-8" }, [ page(id, params["scope"]) ] ]
    end

    def page(id, scope)
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>PSC SIMULADO</title></head>
        <body style="font-family:sans-serif;max-width:32rem;margin:3rem auto">
        <h1>PSC SIMULADO — desenvolvimento</h1>
        <p>Pedido de autorização: <strong>#{Rack::Utils.escape_html(scope)}</strong>. Nenhum certificado real é usado.</p>
        <p><a href="/v0/oauth/authorize/decision?id=#{id}&amp;approve=1">Aprovar</a> ·
           <a href="/v0/oauth/authorize/decision?id=#{id}&amp;approve=0">Recusar</a></p>
        </body></html>
      HTML
    end

    def decision(id, approve)
      pending = @mutex.synchronize { @pending.delete(id) }
      raise ArgumentError, "autorização desconhecida" unless pending

      query = { error: "access_denied", state: pending[:state] }
      if approve
        code = SecureRandom.urlsafe_base64(24)
        @mutex.synchronize { @codes[code] = pending }
        query = { code: code, state: pending[:state] }
      end
      separator = pending[:redirect_uri].include?("?") ? "&" : "?"
      "#{pending[:redirect_uri]}#{separator}#{URI.encode_www_form(query)}"
    end

    def token(request)
      params = request.POST
      return json(401, { error: "invalid_client" }) unless client?(params["client_id"], params["client_secret"])
      return json(400, { error: "unsupported_grant_type" }) unless params["grant_type"] == "authorization_code"

      grant = @mutex.synchronize { @codes.delete(params["code"].to_s) }
      return json(400, { error: "invalid_grant" }) unless grant && grant[:redirect_uri] == params["redirect_uri"]

      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(params["code_verifier"].to_s), padding: false)
      return json(400, { error: "invalid_grant" }) unless Rack::Utils.secure_compare(challenge, grant[:challenge])

      ttl = ONE_SHOT_TTL
      ttl = @forced_lifetime || [ grant[:lifetime] || @max_lifetime, @max_lifetime ].min if grant[:scope] == "signature_session"
      access = issue_token(grant[:cpf], grant[:scope], ttl)
      json(200, { access_token: access, token_type: "Bearer", expires_in: ttl, scope: grant[:scope],
                  authorized_identification_type: "CPF", authorized_identification: grant[:cpf] })
    end

    def certificates(request)
      token = bearer(request)
      return json(401, { error: "invalid_token" }) unless token

      json(200, { status: "S",
                  certificates: [ { alias: token[:cpf], certificate: Base64.strict_encode64(leaf(token[:cpf]).der) } ] })
    end

    def signature(request)
      token = bearer(request)
      return json(401, { error: "invalid_token" }) unless token

      body = parse_json(request)
      hashes = Array(body["hashes"])
      return json(400, { error: "invalid_request" }) if hashes.empty? || body["certificate_alias"] != token[:cpf]
      return json(400, { error: "invalid_request" }) if token[:scope] == "single_signature" && hashes.size != 1
      return json(401, { error: "invalid_token" }) if %w[single_signature multi_signature].include?(token[:scope]) && token[:uses].positive?

      @before_sign&.call
      key = leaf(token[:cpf]).key
      signatures = hashes.map do |item|
        digest = Base64.strict_decode64(item["hash"].to_s)
        unless item["hash_algorithm"] == SHA256_OID && item["signature_format"] == "RAW" && digest.bytesize == 32
          return json(400, { error: "invalid_request" })
        end

        { id: item["id"], raw_signature: Base64.strict_encode64(key.sign_raw("SHA256", digest)) }
      end
      @mutex.synchronize { token[:uses] += 1 }
      json(200, { certificate_alias: token[:cpf], signatures: signatures })
    end

    def bearer(request)
      value = request.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer (.+)\z/, 1]
      token = value && @mutex.synchronize { @tokens[value] }
      token if token && token[:expires_at] > Time.now
    end

    def issue_token(cpf, scope, ttl)
      access = SecureRandom.urlsafe_base64(32)
      @mutex.synchronize { @tokens[access] = { cpf: cpf, scope: scope, expires_at: Time.now + ttl, uses: 0 } }
      access
    end

    def client?(id, secret) = id == @client_id && secret == @client_secret

    def parse_json(request)
      text = request.body.read.to_s
      parsed = JSON.parse(text.empty? ? "{}" : text)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def json(status, object) = [ status, { "content-type" => "application/json" }, [ JSON.generate(object) ] ]
  end
end
