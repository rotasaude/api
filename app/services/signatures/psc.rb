# API de PSC do ITI (DOC-ICP-17.01; ADR 0032). Nenhuma mensagem de erro
# carrega token, code, verifier, CPF, segredo ou corpo de resposta.
module Signatures
  module Psc
    class Error < StandardError; end
    # Rede, timeout, 5xx: tentar de novo depois.
    class Unavailable < Error; end

    # 4xx: o PSC recusou (o código é o "error" da resposta, ou http_<status>).
    class Rejected < Error
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super("o PSC recusou: #{@code}")
      end
    end

    # 401/403: token vencido, revogado ou credencial da plataforma recusada.
    class Unauthorized < Rejected; end

    SCOPES = %w[single_signature multi_signature signature_session].freeze

    Token = Data.define(:access_token, :expires_in, :scope) do
      def inspect = "#<Signatures::Psc::Token scope=#{scope} expires_in=#{expires_in}>"
      alias_method :to_s, :inspect
    end

    CertificateEntry = Data.define(:certificate_alias, :der) do
      def inspect = "#<Signatures::Psc::CertificateEntry>"
    end
  end
end
