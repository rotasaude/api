# Resposta da emissão do 19 (ADR 0033; contrato §3), comum à consulta, ao
# atendimento e à ação do CAPS (módulo 31, P8): 201 <document> ou a recusa
# `{ error, field? | feature? }` com o status do 19.
module ClinicalDocumentResponses
  extend ActiveSupport::Concern

  private

  def respond_created(result)
    if result.failure?
      return render(json: AttendanceAccess.failure_payload(result),
                    status: ClinicalDocumentsController::ERROR_STATUS.fetch(result.reason, :unprocessable_entity))
    end

    render json: ClinicalDocuments::Json.document(result.payload[:document]), status: :created
  end
end
