# Serviço interno signer (ADR 0032; contrato §9): prepara, monta e valida
# CAdES/PAdES AD-RB. Sem estado; o documento nunca sai da infraestrutura.
module Signatures
  module Signer
    class Error < StandardError; end
    # Rede, 5xx (inclui 500 de /prepare com LCR fora do ar: transitório), 401
    # (token errado é configuração) ou URL ausente.
    class Unavailable < Error; end

    # 400/422 com o código do contrato (invalid_request, invalid_certificate,
    # invalid_signature_value). Não transitório.
    class Rejected < Error
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super("o signer recusou: #{@code}")
      end
    end

    KINDS = %w[cades pades].freeze
    STATUSES = %w[valid invalid indeterminate].freeze

    # inspect/pretty_print nunca mostram bytes, CPF ou nome (pp usa pretty_print,
    # não inspect, então os dois são sobrescritos).
    module Redacted
      def pretty_print(pp) = pp.text(inspect)
    end

    Prepared = Data.define(:digest, :state) do
      include Redacted

      def inspect = "#<Signatures::Signer::Prepared>"
    end
    Assembled = Data.define(:signature, :validation_material) do
      include Redacted

      def inspect = "#<Signatures::Signer::Assembled #{signature.bytesize} bytes>"
    end
    Verification = Data.define(:status, :signer_cpf, :signer_name, :policy_oid, :signed_at, :reasons) do
      include Redacted

      def valid? = status == "valid"
      def inspect = "#<Signatures::Signer::Verification #{status} #{reasons.join(',')}>"
    end
    CertificateCheck = Data.define(:status, :signer_cpf, :not_after, :reasons) do
      include Redacted

      def inspect = "#<Signatures::Signer::CertificateCheck #{status} #{reasons.join(',')}>"
    end

    module_function

    def client = Client.new(url: ENV["SIGNER_URL"], token: ENV["SIGNER_TOKEN"])
  end
end
