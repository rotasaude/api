# Documentos do 19 a partir da ação do CAPS (ADR 0049; contrato §4, §9, P4, P8;
# plano, Desvio 12):
#   POST /psychosocial/actions/:id/documents  { kind, content, replaces_document_id? }
#        → 201 <document> do 19 (ClinicalDocumentsController#respond_created);
#        só receita, registro da Notificação e atestado (senão 422
#        invalid_content `field: "kind"`); o profissional da ação (403
#        not_author), ação individual com o participante matriculado e CBO
#        médico (422 prescriber_required); ação cancelada → 409
#        already_cancelled. Atrás também do interruptor clinical_documents.
#   GET  /psychosocial/actions/:id/documents  → { items: [<document>] } da
#        ação, mais novo primeiro, com o bloco do 19b; trilha `resource:
#        "documents"` do paciente quando há documento.
# Ação de CAPS em que quem pede não está lotado → 404. Impressão, cancelamento
# e verificação pública pelas rotas do 19 (/attendance/documents/:id/...).
module Psychosocial
  class DocumentsController < BaseController
    include ::ClinicalDocumentsGate

    # O formato de recusa do 19 (`{ error, field? | feature? }`).
    DOCUMENT_STATUS = ::ClinicalDocumentsController::ERROR_STATUS.merge(already_cancelled: :conflict,
                                                                       prescriber_required: :unprocessable_entity).freeze
    BODY_KEYS = %w[kind content replaces_document_id].freeze

    before_action :require_clinical_documents!, only: :create
    before_action :load_action

    def index
      documents = ClinicalDocument.where(psychosocial_action_id: @caps_action.id).includes(:patient, author_user: :professional)
                                  .order(issued_at: :desc, id: :desc).to_a
      documents.filter_map(&:patient_id).uniq.each do |patient_id|
        Trail.viewed!(patient: patient_id, user: Current.user, resource: "documents")
      end
      blocks = Signatures::Mode.blocks(documents)
      render json: { items: documents.map { |document| ::ClinicalDocuments::Json.document(document, signature: signature(blocks, document)) } }
    end

    def create
      unknown = (body.keys - BODY_KEYS).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      result = ::ClinicalDocuments::Issue.call(kind: body["kind"], content: body["content"], by: Current.user,
                                               psychosocial_action: @caps_action,
                                               replaces_document_id: body["replaces_document_id"])
      if result.failure?
        payload = { error: result.reason.to_s }.merge(result.details)
        return render(json: payload, status: DOCUMENT_STATUS.fetch(result.reason, :unprocessable_entity))
      end

      render json: ::ClinicalDocuments::Json.document(result.payload[:document]), status: :created
    end

    private

    # A ação da URL (como ActionsController#load_action): sem o papel do CAPS
    # → 403 missing_role; id malformado, inexistente ou de CAPS em que quem
    # pede não está lotado → 404. Nada na query.
    def load_action
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      @caps_action = uuid?(params[:id]) ? PsychosocialAction.includes(:psychosocial_action_participants).find_by(id: params[:id]) : nil
      not_found unless @caps_action && Access.can_read?(Current.user, @caps_action)
    end

    # Como ClinicalDocumentsController#with_signatures: sem pedido (papel puro), null.
    def signature(blocks, document)
      block = blocks[[ "ClinicalDocument", document.id ]]
      block&.key?(:request_id) ? block : nil
    end
  end
end
