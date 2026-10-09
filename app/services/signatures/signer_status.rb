# Estado do serviço signer para o maintenance (contrato §8): chama o /health
# real (com token) e nunca levanta; fora do ar vira reachable false.
module Signatures
  module SignerStatus
    Row = Data.define(:reachable, :version, :crl_updated_at)

    module_function

    def call(signer: Signer.client)
      health = signer.health
      Row.new(reachable: true, version: health[:version].presence, crl_updated_at: health[:crl_updated_at])
    rescue StandardError => e
      Rails.logger.warn("[signer_status] #{e.class}")
      Row.new(reachable: false, version: nil, crl_updated_at: nil)
    end
  end
end
