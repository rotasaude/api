# app/controllers/patient_medications_controller.rb
# Medicamentos em uso (ADR 0033; contrato §4). Leitura: regra do prontuário
# (contexto ou abertura), com trilha. Escrita: a autora, na consulta em
# rascunho, pelo caminho único (Patients::ApplyMedicationEvent), com o
# paciente travado aqui (o comando não trava); catálogo lido FORA da
# transação. Renovação: a autora.
class PatientMedicationsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include ClinicalDocumentsGate

  ERROR_STATUS = { not_author: :forbidden, not_draft: :conflict, already_active: :conflict }.freeze

  wrap_parameters false
  before_action :require_clinical_record!
  before_action :require_clinical_documents!, only: :create
  before_action :require_professional

  def index
    patient = uuid?(params[:id]) ? Patient.find_by(id: params[:id]) : nil
    return not_found unless patient

    grant = ClinicalRecord::Access.call(user: Current.user, patient: patient)
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant)
    medications = PatientMedication.where(patient_id: patient.id).order(:status, updated_at: :desc, id: :desc).to_a
    catalog = MedicationCatalogItem.where(id: medications.filter_map(&:catalog_item_id)).index_by(&:id)
    render json: { items: medications.map { |medication| ClinicalDocuments::Json.medication(medication, catalog: catalog) } }
  end

  # O corpo do contrato usa a chave `action`, que no `params` é o nome da ação
  # do Rails (o roteamento vence): o corpo é lido de request.request_parameters.
  def create
    consultation = find_consultation
    return not_found unless consultation
    return forbid("not_author") unless consultation.author_user_id == Current.user.id
    return render(json: { error: "not_draft" }, status: :conflict) unless consultation.draft?

    input = request.request_parameters
    catalog_item = nil
    if input["catalog_item_id"].present?
      catalog_item = uuid?(input["catalog_item_id"]) ? MedicationCatalogItem.where(status: "active").find_by(id: input["catalog_item_id"]) : nil
      return render(json: { error: "invalid_content", field: "catalog_item_id" }, status: :unprocessable_entity) unless catalog_item
    end
    result = apply(consultation, input["action"], catalog_item, input)
    return render_failure(result, ERROR_STATUS) if result.failure?

    medication = result.payload[:medication]
    catalog = MedicationCatalogItem.where(id: medication.catalog_item_id).index_by(&:id)
    render json: ClinicalDocuments::Json.medication(medication.reload, catalog: catalog)
  end

  def renewal
    consultation = find_consultation
    return not_found unless consultation
    return forbid("not_author") unless consultation.author_user_id == Current.user.id

    # A renovação expõe a lista do paciente: a mesma regra e a mesma trilha do index.
    grant = ClinicalRecord::Access.call(user: Current.user, patient: consultation.patient)
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant)
    render json: { items: ClinicalDocuments::Renewal.items(consultation) }
  end

  private

  # Descartada (card api#51) é casca sem conteúdo: inexistente aqui (404).
  def find_consultation = uuid?(params[:id]) ? Consultation.where.not(status: "discarded").find_by(id: params[:id]) : nil

  def apply(consultation, action, catalog_item, input)
    ApplicationRecord.transaction do
      patient = Patient.lock.find(consultation.patient_id)
      # Finalizada entre a checagem e a trava: a consulta relida sob a trava do paciente.
      next Result.fail(:not_draft) unless consultation.reload.draft?

      common = { patient: patient, by: Current.user, source: { consultation: consultation } }
      case action
      when "add_external"
        free_text = input["free_text"]
        if catalog_item.nil? && !(free_text.is_a?(String) && free_text.squish.size.between?(3, 200))
          next Result.fail(:invalid_content, details: { field: "free_text" })
        end
        summary = input["dosage_summary"]
        next Result.fail(:invalid_content, details: { field: "dosage_summary" }) unless summary.nil? || (summary.is_a?(String) && summary.size <= 200)
        next Result.fail(:invalid_content, details: { field: "continuous" }) if input.key?("continuous") && ![ true, false ].include?(input["continuous"])

        Patients::ApplyMedicationEvent.call(**common, action: "add", origin: "external", catalog_item: catalog_item,
                                            free_text: catalog_item ? nil : free_text, dosage_summary: summary,
                                            continuous: input.fetch("continuous", true), on_active: :fail)
      when "suspend", "reactivate"
        medication = uuid?(input["medication_id"]) ? PatientMedication.find_by(id: input["medication_id"], patient_id: patient.id) : nil
        next Result.fail(:invalid_medication) unless medication

        Patients::ApplyMedicationEvent.call(**common, action: action, medication: medication)
      else
        Result.fail(:invalid_content, details: { field: "action" })
      end
    end
  end

  def uuid?(value) = ClinicalDocuments::Uuid.valid?(value)
  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
