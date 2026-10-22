# Rotas das linhas de cuidado (ADR 0040; contrato §1): interruptor desligado
# ou sem o prontuário utilizável → 403 feature_disabled. O controller declara
# o `before_action :require_care_lines!` (como ClinicalRecordGate).
module CareLinesGate
  private

  def require_care_lines!
    return if CareLines::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: CareLines::Gate::KEY }, status: :forbidden
  end
end
