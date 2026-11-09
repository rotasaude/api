# Rotas de /urgency/*: interruptor desligado ou sem pré-requisito → 403
# feature_disabled. A base declara `before_action :require_urgency!`.
module UrgencyGate
  private

  def require_urgency!
    return if Urgency::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Urgency::Gate::KEY }, status: :forbidden
  end
end
