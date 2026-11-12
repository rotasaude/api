# Rotas da visita domiciliar (ADR 0052): interruptor desligado ou sem o cadastro
# territorial utilizável → 403 feature_disabled. O controller declara
# `before_action :require_home_visits!`.
module HomeVisitsGate
  private

  def require_home_visits!
    return if HomeVisits::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: HomeVisits::Gate::KEY }, status: :forbidden
  end
end
