# GET /lab/instruments?provider_id= (contrato §2): leitura para membros do laboratório e admin (C2).
# C13: com lab_quality_control ou lab_inventory utilizável.
module Lab
  class InstrumentsController < BaseController
    before_action do
      next if Lab::Gate.instruments_usable?(Current.city)

      render json: { error: "feature_disabled", feature: Lab::Gate::QC_KEY }, status: :forbidden
    end

    def index
      provider = uuid?(params[:provider_id]) && Lab::Access.labs.find_by(id: params[:provider_id])
      return not_found unless provider
      return forbid unless Lab::Access.member?(Current.user, provider.id) || Lab::Access.admin?(Current.user)

      render json: { instruments: LabInstrument.where(exam_provider_id: provider.id).order(:name).map { |i| Lab::AdminJson.instrument(i) } }
    end
  end
end
