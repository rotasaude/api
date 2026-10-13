# app/controllers/clinical_documents_controller.rb
# Documentos clínicos (ADR 0033; contrato §3). Emitir: da consulta (autora) ou
# do atendimento (declaração); interruptor clinical_documents. Ler: autora
# sempre, demais pelas regras do 19a, com trilha; segue com o interruptor
# desligado (atrás só do clinical_record). Impresso e cancelamento (autora,
# step-up; segue com o interruptor desligado) moram aqui.
class ClinicalDocumentsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include ClinicalDocumentsGate
  include MfaStepUp

  ERROR_STATUS = {
    not_author: :forbidden, cbo_not_allowed: :forbidden, missing_role: :forbidden, out_of_context: :forbidden,
    feature_disabled: :forbidden, not_found: :not_found, already_cancelled: :conflict, awaiting_signature: :conflict,
    attendance_not_found_or_closed_long_ago: :conflict, catalog_unavailable: :service_unavailable,
    attendance_outside_unit: :unprocessable_entity
  }.freeze
  IDENTIFICATION_LOOKBACK = 50

  wrap_parameters false
  before_action :require_clinical_record!
  before_action :require_clinical_documents!, only: %i[create declaration]
  before_action :require_staff
  before_action :require_step_up!, only: :cancel

  def index
    consultation = find_consultation
    return not_found unless consultation

    grant = ClinicalDocuments::Read.consultation_grant(user: Current.user, consultation: consultation)
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant)
    documents = ClinicalDocument.where(consultation_id: consultation.id).includes(:patient, author_user: :professional)
                                .order(issued_at: :desc, id: :desc).to_a
    render json: { items: with_signatures(documents) }
  end

  def create
    consultation = find_consultation
    return not_found unless consultation

    result = ClinicalDocuments::Issue.call(kind: body["kind"], content: body["content"], by: Current.user,
                                           consultation: consultation, replaces_document_id: body["replaces_document_id"])
    respond_created(result)
  end

  def declaration
    attendance = find(Attendance, params[:id])
    return not_found unless attendance
    # api#59: só atendimento da unidade escolhida no seletor (guarda contra engano).
    return outside_unit unless unit_param == attendance.health_unit_id

    result = ClinicalDocuments::Issue.call(kind: "attendance_declaration", content: body["content"], by: Current.user,
                                           attendance: attendance)
    respond_created(result)
  end

  # api#59: as declarações do atendimento, para a recepção reimprimir e cancelar.
  # Só metadados (o que a fila já mostra); a leitura fica na trilha.
  def attendance_declarations
    attendance = find(Attendance, params[:id])
    return not_found unless attendance
    return outside_unit unless unit_param == attendance.health_unit_id

    render json: { items: declaration_rows(ClinicalDocument.where(attendance_id: attendance.id)) }
  end

  # api#59: as declarações do dia (fuso da cidade) nos atendimentos da unidade.
  def declarations
    unit_id = unit_param
    return outside_unit unless unit_id && HealthUnit.exists?(id: unit_id)

    day = begin
      Date.iso8601(params[:date].to_s)
    rescue Date::Error
      Time.zone.today
    end
    scope = ClinicalDocument.joins(:attendance).where(attendances: { health_unit_id: unit_id }).where(issued_at: day.in_time_zone.all_day)
    render json: { items: declaration_rows(scope) }
  end

  def show
    document = readable_document
    render json: ClinicalDocuments::Json.document(document) if document
  end

  # "Reaproveitar o último" (19d spec §5; contrato §12): a identificação do
  # paciente da última receita emitida dele que a tenha — só o endereço; o CPF
  # é sempre o do cadastro (§12), nunca o gravado na receita. Só a autora da
  # consulta (é ela quem emite a próxima receita), pela regra do prontuário
  # (ClinicalRecord::Access via Read.consultation_grant), com trilha.
  def patient_identification
    consultation = find_consultation
    return not_found unless consultation
    return forbid("not_author") unless consultation.author_user_id == Current.user.id

    grant = ClinicalDocuments::Read.consultation_grant(user: Current.user, consultation: consultation)
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: consultation.patient, user: Current.user, grant: grant)
    address = ClinicalDocument.where(patient_id: consultation.patient_id, kind: "prescription", status: "issued")
                              .order(issued_at: :desc, id: :desc).limit(IDENTIFICATION_LOOKBACK)
                              .lazy.map { |document| document.content_data.dig("patient_identification", "address") }.find(&:present?)
    cpf = CitizenIdentity::Cpf.normalize(consultation.patient.cpf.to_s)
    render json: { patient_identification: address && { cpf: cpf, address: address } }
  end

  # Contrato §3 (Desvio 7): o PDF do modo do documento, na hora, sem cache.
  # Digital: só depois de assinado (o papel de um digital pendente criaria duas
  # vias válidas com o mesmo código); papel: gerado agora.
  def print
    document = readable_document
    return unless document
    return not_found if document.notification_record?
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

  # Contrato §3 (Desvio 13): só a autora, com step-up; segue com o interruptor
  # desligado (protege o paciente).
  def cancel
    result = ClinicalDocuments::Cancel.call(document_id: params[:id], by: Current.user, reason: body["reason"],
                                            health_unit_id: unit_param)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: ClinicalDocuments::Json.document(result.payload[:document].reload)
  end

  private

  # Recepção (citizen_verifier) só na declaração, nas listas dela, na leitura/
  # impresso e no cancelamento (o comando restringe à declaração; api#59); o
  # resto é do profissional.
  RECEPTION_ACTIONS = %w[declaration attendance_declarations declarations show print cancel].freeze
  def require_staff
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    allowed = RECEPTION_ACTIONS.include?(action_name) ? policy.care? || policy.verify? : policy.care?
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

    grant = ClinicalDocuments::Read.document_grant(user: Current.user, document: document, health_unit_id: unit_param)
    return forbid(grant.reason.to_s).then { nil } unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: document.patient, user: Current.user, grant: grant)
    document
  end

  def respond_created(result)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: ClinicalDocuments::Json.document(result.payload[:document]), status: :created
  end

  # A unidade do seletor da tela (api#59): na query ou no corpo; só UUID.
  def unit_param
    raw = params[:health_unit_id].presence || body["health_unit_id"]
    raw.is_a?(String) && ClinicalDocuments::Uuid.valid?(raw) ? raw : nil
  end

  def outside_unit = render_failure(Result.fail(:attendance_outside_unit), ERROR_STATUS)

  # A listagem registra leitura (spec da rodada §7): uma trilha por declaração
  # com paciente, com o acesso declaration_list.
  LIST_GRANT = ClinicalRecord::Access::Grant.new(kind: :declaration_list, opening: nil, reason: nil)

  def declaration_rows(scope)
    documents = scope.where(kind: "attendance_declaration").includes(:patient, :author_user, attendance: :citizen)
                     .order(issued_at: :desc, id: :desc).to_a
    documents.each { |document| ClinicalRecord::Trail.viewed!(patient: document.patient, user: Current.user, grant: LIST_GRANT) }
    documents.map { |document| ClinicalDocuments::Json.declaration_row(document) }
  end

  def find(model, id) = ClinicalDocuments::Uuid.valid?(id) ? model.find_by(id: id) : nil
  # Descartada (card api#51) é casca sem conteúdo: inexistente aqui (404).
  def find_consultation = find(Consultation, params[:id]).then { |consultation| consultation unless consultation&.discarded? }
  def body = params.to_unsafe_h.except("controller", "action", "id", "format")
  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
