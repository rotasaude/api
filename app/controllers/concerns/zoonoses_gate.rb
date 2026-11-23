# Rotas do centro de zoonoses (ADR 0054; contrato §1): interruptor desligado ou
# sem o cadastro territorial utilizável → 403 feature_disabled. O controller
# declara `before_action :require_zoonoses!`.
module ZoonosesGate
  private

  def require_zoonoses!
    return if Zoonoses::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Zoonoses::Gate::KEY }, status: :forbidden
  end
end
