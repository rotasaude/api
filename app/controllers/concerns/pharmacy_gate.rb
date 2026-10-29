# Rotas da farmácia (ADR 0045): interruptor desligado → 403 feature_disabled.
# O Pharmacy::BaseController declara o `before_action :require_pharmacy!`.
module PharmacyGate
  private

  def require_pharmacy!
    return if Pharmacy::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Pharmacy::Gate::KEY }, status: :forbidden
  end
end
