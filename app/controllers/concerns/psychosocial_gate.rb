# Rotas de /psychosocial/*: interruptor desligado ou sem pré-requisito → 403
# feature_disabled. A base declara `before_action :require_psychosocial!`.
module PsychosocialGate
  private

  def require_psychosocial!
    return if Psychosocial::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Psychosocial::Gate::KEY }, status: :forbidden
  end
end
