# Rotas do envio ao SI-BNAFAR (módulo 27b): interruptor desligado ou inutilizável
# → 403 feature_disabled. O controller declara `before_action :require_bnafar!`.
module BnafarGate
  private

  def require_bnafar!
    return if Bnafar::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Bnafar::Gate::KEY }, status: :forbidden
  end
end
