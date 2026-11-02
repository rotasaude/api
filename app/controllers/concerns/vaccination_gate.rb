# Rotas da sala de vacina (ADR 0047): interruptor desligado → 403
# feature_disabled. O controller declara `before_action :require_vaccination!`.
module VaccinationGate
  private

  def require_vaccination!
    return if Vaccination::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: Vaccination::Gate::KEY }, status: :forbidden
  end
end
