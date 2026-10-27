# Rotas da vigilância epidemiológica (ADR 0043; contrato §1): interruptor
# desligado → 403 feature_disabled. O controller declara o
# `before_action :require_surveillance!` (como CareLinesGate). As rotas que
# consultam o prontuário usam `require_surveillance_consultation!`: aponta o
# interruptor que falta (surveillance, ou clinical_record quando só o
# prontuário está fora).
module SurveillanceGate
  private

  def require_surveillance!
    return if Surveillance::Gate.usable?(Current.city)

    render_surveillance_disabled(Surveillance::Gate::KEY)
  end

  def require_surveillance_consultation!
    city = Current.city
    return render_surveillance_disabled(Surveillance::Gate::KEY) unless Surveillance::Gate.usable?(city)
    return if ClinicalRecord::Gate.usable?(city)

    render_surveillance_disabled(ClinicalRecord::Gate::KEY)
  end

  def render_surveillance_disabled(feature)
    render json: { error: "feature_disabled", feature: feature }, status: :forbidden
  end
end
