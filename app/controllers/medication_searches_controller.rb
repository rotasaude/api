# app/controllers/medication_searches_controller.rb
# Busca de medicamentos para a receita, o "medicamento em uso de fora", a
# REMUME e os protocolos (ADR 0033; contrato §5). Profissional ou
# municipal_admin; interruptor clinical_documents.
class MedicationSearchesController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalDocumentsGate

  wrap_parameters false
  before_action :require_clinical_documents!
  before_action :require_searcher

  def search
    unit_id = params[:unit_id].is_a?(String) ? params[:unit_id] : nil
    render json: { items: Medications::Search.call(q: params[:q].to_s, unit_id: unit_id) }
  rescue Medications::Search::Unavailable
    render json: { error: "catalog_unavailable" }, status: :service_unavailable
  end

  private

  # Profissional (receita, medicamento de fora) ou municipal_admin (REMUME e
  # protocolos): o catálogo não tem dado de paciente.
  def require_searcher
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid("missing_role") unless policy.care? || policy.manage?
  end
end
