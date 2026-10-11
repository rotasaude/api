# Rotas do 19d (ADR 0034; contrato): interruptor desligado ou sem os
# documentos clínicos utilizáveis → 403 feature_disabled.
module ControlledPrescriptionsGate
  extend ActiveSupport::Concern

  private

  def require_controlled_prescriptions!
    return if ControlledPrescriptions::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: ControlledPrescriptions::Gate::KEY }, status: :forbidden
  end
end
