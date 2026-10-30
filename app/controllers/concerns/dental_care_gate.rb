# Rotas da saúde bucal (ADR 0046): interruptor desligado → 403
# feature_disabled. O controller declara o `before_action :require_dental_care!`
# (como CareRegulationGate). Aponta o interruptor que falta: dental_care, ou
# clinical_record quando só o prontuário está fora.
module DentalCareGate
  private

  def require_dental_care!
    city = Current.city
    return render_dental_care_disabled(DentalCare::Gate::KEY) unless DentalCare::Gate.enabled?(city)
    return if DentalCare::Gate.usable?(city)

    render_dental_care_disabled(ClinicalRecord::Gate::KEY)
  end

  def render_dental_care_disabled(feature)
    render json: { error: "feature_disabled", feature: feature }, status: :forbidden
  end
end
