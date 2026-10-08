# Rotas do prontuário (ADR 0031; contratos): interruptor desligado ou sem
# record_mode = record → 403 feature_disabled, antes de qualquer leitura.
module ClinicalRecordGate
  extend ActiveSupport::Concern

  private

  def require_clinical_record!
    return if ClinicalRecord::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: ClinicalRecord::Gate::KEY }, status: :forbidden
  end
end
