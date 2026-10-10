# Configuração dos documentos clínicos da cidade (ADR 0033; contrato §6):
# CNPJ, REMUME e protocolos de enfermagem. Atrás do prontuário (a cidade
# prepara antes de ligar clinical_documents); escrita só do municipal_admin,
# com step-up; leitura também do profissional.
module ClinicalDocuments
  class BaseController < ApplicationController
    include Authentication
    include AttendanceAccess
    include ClinicalRecordGate
    include MfaStepUp

    UUID = ClinicalDocuments::Uuid::PATTERN

    wrap_parameters false
    before_action :require_clinical_record!

    private

    def policy = (@policy ||= CitizenVerificationPolicy.new(Current.user, nil))
    def require_admin_role = (forbid("missing_role") unless policy.manage?)
    def require_reader_role = (forbid("missing_role") unless policy.manage? || policy.care?)
    # Só o ruído do Rails sai; "catalog_item_id" fica (o create da REMUME lê).
    def body = params.to_unsafe_h.except("controller", "action", "id", "format")
    def unprocessable(error, **extra) = render(json: { error: error, **extra }, status: :unprocessable_entity)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = ClinicalDocuments::Uuid.valid?(value)
  end
end
