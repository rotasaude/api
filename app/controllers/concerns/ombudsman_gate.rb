# Rotas da ouvidoria: interruptor desligado ou sem pré-requisito → 403
# feature_disabled. A denúncia anônima pública usa `require_ombudsman_anonymous!`.
module OmbudsmanGate
  private

  def require_ombudsman!
    return if Ombudsman::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Ombudsman::Gate::KEY }, status: :forbidden
  end

  def require_ombudsman_anonymous!
    return if Ombudsman::AnonymousGate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Ombudsman::AnonymousGate::KEY }, status: :forbidden
  end
end
