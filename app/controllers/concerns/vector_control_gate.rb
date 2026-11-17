# Rotas da vigilância ambiental (ADR 0054): interruptor desligado ou sem a
# visita domiciliar utilizável → 403 feature_disabled. O controller declara
# `before_action :require_vector_control!`.
module VectorControlGate
  private

  def require_vector_control!
    return if VectorControl::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: VectorControl::Gate::KEY }, status: :forbidden
  end
end
