# Rotas de /tfd/*: interruptor desligado ou sem pré-requisito → 403
# feature_disabled. A base declara `before_action :require_tfd!`.
module TfdGate
  private

  def require_tfd!
    return if Tfd::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Tfd::Gate::KEY }, status: :forbidden
  end
end
