# Rotas da regulação municipal (ADR 0044; contrato §1): interruptor desligado
# → 403 feature_disabled. O controller declara o
# `before_action :require_care_regulation!` (como SurveillanceGate). Aponta o
# interruptor que falta: care_regulation, ou clinical_record quando só o
# prontuário está fora.
module CareRegulationGate
  private

  def require_care_regulation!
    city = Current.city
    return render_care_regulation_disabled(CareRegulation::Gate::KEY) unless CareRegulation::Gate.enabled?(city)
    return if CareRegulation::Gate.usable?(city)

    render_care_regulation_disabled(ClinicalRecord::Gate::KEY)
  end

  def render_care_regulation_disabled(feature)
    render json: { error: "feature_disabled", feature: feature }, status: :forbidden
  end
end
