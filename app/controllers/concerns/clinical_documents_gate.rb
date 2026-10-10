# Escritas dos documentos clínicos (ADR 0033; contrato): interruptor desligado
# ou sem o prontuário utilizável → 403 feature_disabled.
module ClinicalDocumentsGate
  extend ActiveSupport::Concern

  private

  def require_clinical_documents!
    return if ClinicalDocuments::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: ClinicalDocuments::Gate::KEY }, status: :forbidden
  end
end
