# GET /lab/hl7/pending_barcodes (contrato §12): códigos de amostras aceitas
# com exame pendente do laboratório do token. Sem paciente.
module Hl7
  class PendingBarcodesController < BaseController
    def index
      return render(json: { error: "token_revoked" }, status: :unauthorized) if @token.revoked?
      if @token.simulated && !fake_allowed?
        return render(json: { error: "feature_disabled", feature: Lab::Gate::FAKE_KEY }, status: :forbidden)
      end

      # Teto de 200 códigos por chamada, em ordem de código: o middleware repete a consulta
      # (runbook). Passar do teto não é erro, só a lista seguinte.
      barcodes = LabSample.joins(:lab_requisition, :items)
                          .where(lab_requisitions: { exam_provider_id: @token.exam_provider_id }, status: LabSample::ACCEPTED,
                                 lab_requisition_items: { status: "pending" })
                          .distinct.order(:barcode).limit(200).pluck(:barcode)
      render json: { barcodes: barcodes }
    end
  end
end
