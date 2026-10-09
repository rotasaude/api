# Cliente HTTP do signer (contrato §9). Corpo nunca logado; nenhuma mensagem
# carrega token, documento ou CPF.
require "net/http"

module Signatures
  module Signer
    class Client
      TIMEOUT = 30
      NETWORK_ERRORS = [ SocketError, IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
                         Net::WriteTimeout, Net::ProtocolError, OpenSSL::SSL::SSLError ].freeze

      def initialize(url:, token:, timeout: TIMEOUT)
        @url = url.to_s.chomp("/")
        @token = token.to_s
        @timeout = timeout
      end

      def prepare(kind:, document:, certificate_der:)
        body = post("/prepare", kind: kind!(kind), document_base64: b64(document),
                                certificate_der_base64: b64(certificate_der), policy: "AD-RB")
        Prepared.new(digest: decode(body, "to_be_signed_sha256_base64"), state: body["prepared_state"].to_s.presence || bad!)
      end

      def assemble(kind:, state:, signature_value:)
        body = post("/assemble", kind: kind!(kind), prepared_state: state, signature_value_base64: b64(signature_value))
        Assembled.new(signature: decode(body, "signature_base64"), validation_material: decode(body, "validation_material_base64"))
      end

      def verify(kind:, signature:, document: nil)
        payload = { kind: kind!(kind), signature_base64: b64(signature) }
        payload[:document_base64] = b64(document) if document
        body = post("/verify", **payload)
        bad! unless STATUSES.include?(body["status"])

        Verification.new(status: body["status"], signer_cpf: body["signer_cpf"].presence, signer_name: body["signer_name"].presence,
                         policy_oid: body["policy_oid"].presence, signed_at: time(body["signed_at"]),
                         reasons: Array(body["reasons"]).map(&:to_s))
      end

      # Contrato D1: cadeia + LCR do certificado, sem assinar (vínculo e renovação).
      def check_certificate(certificate_der:)
        body = post("/certificates/check", certificate_der_base64: b64(certificate_der))
        bad! unless STATUSES.include?(body["status"])

        CertificateCheck.new(status: body["status"], signer_cpf: body["signer_cpf"].presence, not_after: time(body["not_after"]),
                             reasons: Array(body["reasons"]).map(&:to_s))
      end

      def health
        body = perform(Net::HTTP::Get, "/health")
        { version: body["version"].to_s, crl_updated_at: time(body["crl_updated_at"]) }
      end

      def inspect = "#<Signatures::Signer::Client>"
      def pretty_print(pp) = pp.text(inspect)

      private

      def post(path, **payload) = perform(Net::HTTP::Post, path, JSON.generate(payload))

      def perform(verb, path, body = nil)
        raise Unavailable, "SIGNER_URL ausente" if @url.empty?

        uri = URI("#{@url}#{path}")
        request = verb.new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request.body = body
        end
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout,
                                                       read_timeout: @timeout, write_timeout: @timeout) { |http| http.request(request) }
        interpret(response)
      rescue *NETWORK_ERRORS => e
        raise Unavailable, "signer inalcançável (#{e.class.name})"
      end

      # 400/422 = recusa com código; qualquer outro não-200 (401, 5xx) =
      # indisponível. O corpo de erro só entra na mensagem se for um código.
      def interpret(response)
        code = response.code.to_i
        parsed = parse(response.body)
        return parsed if code == 200
        raise Rejected, (parsed["error"].to_s.match?(/\A[a-z_]{1,64}\z/) ? parsed["error"] : "http_#{code}") if [ 400, 422 ].include?(code)

        raise Unavailable, "o signer respondeu #{code}"
      end

      def parse(text)
        parsed = JSON.parse(text.to_s.presence || "{}")
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def kind!(kind)
        raise ArgumentError, "kind fora do contrato" unless KINDS.include?(kind)

        kind
      end

      def b64(bytes) = Base64.strict_encode64(bytes.to_s.b)

      def decode(body, key)
        Base64.strict_decode64(body[key].to_s.presence || bad!)
      rescue ArgumentError
        bad!
      end

      def time(value)
        value.present? ? Time.iso8601(value.to_s) : nil
      rescue ArgumentError
        bad!
      end

      def bad! = raise(Unavailable, "resposta do signer ilegível")
    end
  end
end
