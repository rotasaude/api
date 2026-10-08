# Busca de exame SIGTAP para o pedido da consulta (ADR 0031; contratos §5):
# grupo 02 da competência ativa, até 20; termo no corpo. Sem release: 503.
class SigtapProceduresController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate

  wrap_parameters false

  before_action :require_clinical_record!
  before_action :require_professional

  def search
    today = Time.zone.today
    return render(json: { error: "terminology_unavailable" }, status: :service_unavailable) unless ClinicalTerms::SigtapExams.release(on: today)

    items = ClinicalTerms::SigtapExams.search(params[:q], on: today)
    render json: { items: items.map { |e| { code: e.code, label: e.label } } }
  end
end
