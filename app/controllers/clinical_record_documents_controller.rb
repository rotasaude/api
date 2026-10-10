# Leitura administrativa dos documentos clínicos (ADR 0033; Desvio 11), no
# mesmo desenho da leitura administrativa da consulta do 19a: municipal_admin,
# step-up, consulta finalizada; a linha em clinical_record_administrative_reads
# e a trilha administrative saem juntas, antes de renderizar. Só leitura
# (sem impresso).
class ClinicalRecordDocumentsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include MfaStepUp

  before_action :require_clinical_record!
  before_action :require_admin
  before_action :require_step_up!

  def index
    consultation = params[:id].to_s.match?(ClinicalDocuments::Uuid::PATTERN) && Consultation.finalized_consultations.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless consultation

    grant = ClinicalRecord::Access::Grant.new(kind: :administrative, opening: nil, reason: nil)
    ApplicationRecord.transaction do
      ClinicalRecordAdministrativeRead.create!(user: Current.user, patient: consultation.patient, consultation: consultation)
      ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant, consultation_id: consultation.id)
    end
    documents = ClinicalDocument.where(consultation_id: consultation.id).order(issued_at: :desc, id: :desc)
    render json: { items: documents.map { |document| ClinicalDocuments::Json.document(document) } }
  end
end
