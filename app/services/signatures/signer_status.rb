# Estado do serviço signer para o maintenance (contrato §8): chama o /health
# real (com token) e nunca levanta; fora do ar vira reachable false.
module Signatures
  module SignerStatus
    Row = Data.define(:reachable, :version, :crl_updated_at)

    module_function

    def call(signer: Signer.client)
      health = signer.health
      Row.new(reachable: true, version: health[:version].presence, crl_updated_at: health[:crl_updated_at])
    rescue Signer::Error
      unreachable
    rescue StandardError => e
      Rails.error.report(e, handled: true, severity: :warning) # bug nosso, não "fora do ar": visível, mas a consulta não cai
      unreachable
    end

    def unreachable = Row.new(reachable: false, version: nil, crl_updated_at: nil)
    private_class_method :unreachable
  end
end
