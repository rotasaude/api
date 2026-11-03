# Rotas de /transport/*: interruptor desligado ou sem pré-requisito → 403
# feature_disabled. A base declara `before_action :require_transport!`.
module TransportGate
  private

  def require_transport!
    return if Transport::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Transport::Gate::KEY }, status: :forbidden
  end
end
