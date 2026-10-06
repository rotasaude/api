# Rota de funcionalidade com interruptor (ADR 0028; contratos §1): desligado na
# cidade do host → 403 feature_disabled. "Ligado mas sem o que precisa" é da
# rota (o CADSUS responde 503; a Produção do exportador decide a sua).
module FeatureGate
  extend ActiveSupport::Concern

  class_methods do
    def require_feature(key, **options)
      before_action(-> { require_feature!(key) }, **options)
    end
  end

  private

  def require_feature!(key)
    return if Platform::Features.enabled?(Current.city, key)

    render json: { error: "feature_disabled", feature: key.to_s }, status: :forbidden
  end
end
