# Cliente único da API v0 do ITI para todos os PSC (pesquisa §2; Task 0 Step 3
# conferiu os nomes). Nomes de caminho e de campo moram SÓ aqui e no
# FakePsc::App. Toda chamada registra a checagem do PSC na plataforma.
require "net/http"

module Signatures
  module Psc
    class Client
      TIMEOUT = 15
      SHA256_OID = "2.16.840.1.101.3.4.2.1".freeze
      PATHS = { discovery: "/v0/oauth/user-discovery", authorize: "/v0/oauth/authorize", token: "/v0/oauth/token",
                certificates: "/v0/oauth/certificate-discovery", signature: "/v0/oauth/signature" }.freeze
      NETWORK_ERRORS = [ SocketError, IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
                         Net::WriteTimeout, Net::ProtocolError, OpenSSL::SSL::SSLError ].freeze

      # Resolve pela cidade (interruptor signature_psc_mock; Providers).
      def self.for(key, city: Current.city)
        provider = Providers.find(key, city: city)
        raise Unavailable, "PSC não configurado" unless provider

        new(provider)
      end

      def initialize(provider, timeout: TIMEOUT)
        @provider = provider
        @timeout = timeout
      end

      def discover(cpf)
        body = call(:discovery, json: { client_id: @provider.client_id, client_secret: @provider.client_secret,
                                        user_cpf_cnpj: "CPF", val_cpf_cnpj: cpf })
        body["status"] == "S" && Array(body["slots"]).any?
      end

      def authorize_url(state:, challenge:, scope:, login_hint:, redirect_uri:, lifetime: nil)
        raise ArgumentError, "escopo desconhecido" unless SCOPES.include?(scope)

        query = { response_type: "code", client_id: @provider.client_id, redirect_uri: redirect_uri, state: state,
                  scope: scope, code_challenge: challenge, code_challenge_method: "S256", login_hint: login_hint,
                  lifetime: lifetime }.compact
        "#{@provider.authorize_base_url || @provider.base_url}#{PATHS[:authorize]}?#{URI.encode_www_form(query)}"
      end

      def exchange(code:, verifier:, redirect_uri:)
        body = call(:token, form: { grant_type: "authorization_code", client_id: @provider.client_id,
                                    client_secret: @provider.client_secret, code: code, redirect_uri: redirect_uri,
                                    code_verifier: verifier })
        access = body["access_token"]
        raise Rejected, "invalid_token_response" unless access.is_a?(String) && access.present?

        Token.new(access_token: access, expires_in: Integer(body["expires_in"]), scope: body["scope"].to_s)
      rescue ArgumentError, TypeError
        raise Rejected, "invalid_token_response"
      end

      def certificates(access_token)
        body = call(:certificates, bearer: access_token)
        Array(body["certificates"]).filter_map do |entry|
          der = decode_certificate(entry["certificate"])
          der && CertificateEntry.new(certificate_alias: entry["alias"].to_s, der: der)
        end
      end

      def sign(access_token:, certificate_alias:, digests:)
        hashes = digests.map do |id, digest|
          { id: id.to_s, alias: id.to_s, hash: Base64.strict_encode64(digest), hash_algorithm: SHA256_OID,
            signature_format: "RAW" }
        end
        body = call(:signature, json: { certificate_alias: certificate_alias, hashes: hashes }, bearer: access_token)
        result = Array(body["signatures"]).to_h { |item| [ item["id"].to_s, Base64.strict_decode64(item["raw_signature"].to_s) ] }
        raise Rejected, "incomplete_signatures" unless result.keys.sort == digests.keys.map(&:to_s).sort

        result
      rescue ArgumentError
        raise Rejected, "invalid_signature_response"
      end

      def inspect = "#<Signatures::Psc::Client #{@provider.key}>"

      private

      def call(name, json: nil, form: nil, bearer: nil)
        uri = URI("#{@provider.base_url}#{PATHS.fetch(name)}")
        request = json || form ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        request["Authorization"] = "Bearer #{bearer}" if bearer
        if json
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(json)
        elsif form
          request.set_form_data(form)
        end
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout,
                                                       read_timeout: @timeout, write_timeout: @timeout) { |http| http.request(request) }
        interpret(response)
      rescue *NETWORK_ERRORS => e
        Providers.record_check!(@provider.key, ok: false)
        raise Unavailable, "PSC inalcançável (#{e.class.name})"
      end

      def interpret(response)
        code = response.code.to_i
        body = parse(response.body)
        if code >= 500
          Providers.record_check!(@provider.key, ok: false)
          raise Unavailable, "o PSC respondeu #{code}"
        end
        Providers.record_check!(@provider.key, ok: true)
        return body if code.between?(200, 299)

        error = body["error"].is_a?(String) && body["error"].match?(/\A[a-z_]{1,64}\z/) ? body["error"] : "http_#{code}"
        raise Unauthorized, error if [ 401, 403 ].include?(code)

        raise Rejected, error
      end

      def parse(text)
        parsed = JSON.parse(text.to_s.presence || "{}")
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # Base64 de DER ou PEM, conforme o PSC.
      def decode_certificate(value)
        text = value.to_s
        return OpenSSL::X509::Certificate.new(text).to_der if text.include?("-----BEGIN")

        Base64.strict_decode64(text.gsub(/\s/, ""))
      rescue ArgumentError, OpenSSL::X509::CertificateError
        nil
      end
    end
  end
end
