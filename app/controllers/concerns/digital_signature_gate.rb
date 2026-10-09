# Rotas da assinatura (ADR 0032; contrato): interruptor desligado ou sem o
# prontuário utilizável → 403 feature_disabled, antes de qualquer leitura.
module DigitalSignatureGate
  extend ActiveSupport::Concern

  private

  def require_digital_signature!
    return if Signatures::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Signatures::Gate::KEY }, status: :forbidden
  end
end
