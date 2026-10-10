# app/controllers/clinical_documents_controller.rb
# Documentos clínicos (ADR 0033; contrato §3). Emitir: da consulta (autora) ou
# do atendimento (declaração); interruptor clinical_documents. Ler: autora
# sempre, demais pelas regras do 19a, com trilha; segue com o interruptor
# desligado (atrás só do clinical_record). Impresso e cancelamento (Task 20)
# moram aqui.
class ClinicalDocumentsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include ClinicalDocumentsGate
  include MfaStepUp

  ERROR_STATUS = {
    not_author: :forbidden, cbo_not_allowed: :forbidden, missing_role: :forbidden, out_of_context: :forbidden,
    feature_disabled: :forbidden, not_found: :not_found, already_cancelled: :conflict, awaiting_signature: :conflict,
    attendance_not_found_or_closed_long_ago: :conflict, catalog_unavailable: :service_unavailable
  }.freeze

  wrap_parameters false
  before_action :require_clinical_record!
  before_action :require_clinical_documents!, only: %i[create declaration]
  before_action :require_staff

  def index
    consultation = find(Consultation, params[:id])
    return not_found unless consultation

    grant = ClinicalDocuments::Read.consultation_grant(user: Current.user, consultation: consultation)
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant)
    documents = ClinicalDocument.where(consultation_id: consultation.id).includes(:patient, author_user: :professional)
                                .order(issued_at: :desc, id: :desc).to_a
    render json: { items: with_signatures(documents) }
  end

  def create
    consultation = find(Consultation, params[:id])
    return not_found unless consultation

    result = ClinicalDocuments::Issue.call(kind: body["kind"], content: body["content"], by: Current.user,
                                           consultation: consultation, replaces_document_id: body["replaces_document_id"])
    respond_created(result)
  end

  def declaration
    attendance = find(Attendance, params[:id])
    return not_found unless attendance

    result = ClinicalDocuments::Issue.call(kind: "attendance_declaration", content: body["content"], by: Current.user,
                                           attendance: attendance)
    respond_created(result)
  end

  def show
    document = readable_document
    render json: ClinicalDocuments::Json.document(document) if document
  end

  # Contrato §3 (Desvio 7): o PDF do modo do documento, na hora, sem cache.
  # Digital: só depois de assinado (o papel de um digital pendente criaria duas
  # vias válidas com o mesmo código); papel: gerado agora.
  def print
    document = readable_document
    return unless document
    return render(json: { error: "already_cancelled" }, status: :conflict) if document.cancelled?

    bytes =
      if document.digital?
        # Só o PAdES gravado, sem revalidar e sem PDF gerado de fallback: um
        # segundo PDF com o mesmo código criaria duas vias (Desvio 7).
        signature = document.signed_signature
        return render(json: { error: "awaiting_signature" }, status: :conflict) unless signature

        signature.signed_pdf_bytes
      else
        ClinicalDocuments::Pdf.call(document)
      end
    response.headers["Cache-Control"] = "no-store"
    send_data bytes, type: "application/pdf", disposition: "inline", filename: "documento.pdf"
  end

  private

  # Recepção (citizen_verifier) só na declaração e na leitura/impresso do
  # documento; o resto é do profissional.
  def require_staff
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    allowed = %w[declaration show print].include?(action_name) ? policy.care? || policy.verify? : policy.care?
    forbid("missing_role") unless allowed
  end

  # Bloco do 19b de todos os documentos em duas consultas (Signatures::Mode.blocks);
  # sem pedido (papel puro) → signature null, como em Json.document.
  def with_signatures(documents)
    blocks = Signatures::Mode.blocks(documents)
    documents.map do |document|
      block = blocks[[ "ClinicalDocument", document.id ]]
      ClinicalDocuments::Json.document(document, signature: block&.key?(:request_id) ? block : nil)
    end
  end

  # O documento com a trilha da leitura, ou nil (a resposta de erro já saiu).
  def readable_document
    document = find(ClinicalDocument, params[:id])
    return not_found.then { nil } unless document

    grant = ClinicalDocuments::Read.document_grant(user: Current.user, document: document)
    return forbid(grant.reason.to_s).then { nil } unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: document.patient, user: Current.user, grant: grant)
    document
  end

  def respond_created(result)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: ClinicalDocuments::Json.document(result.payload[:document]), status: :created
  end

  def find(model, id) = ClinicalDocuments::Uuid.valid?(id) ? model.find_by(id: id) : nil
  def body = params.to_unsafe_h.except("controller", "action", "id", "format")
  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
