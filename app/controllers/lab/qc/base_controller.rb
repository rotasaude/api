# Base das rotas /lab/qc/* e /lab/eqa/* (contrato §3–§4; ADR 0038 §8):
# municipal_lab (herdado) e lab_quality_control utilizáveis. Quem lê:
# membro do laboratório ou admin. Quem configura: admin ou RT/substituto.
module Lab
  module Qc
    class BaseController < Lab::BaseController
      include Lab::ProviderScoped

      before_action :require_quality_control!

      private

      def require_quality_control!
        return if Lab::Gate.qc_usable?(Current.city)

        render json: { error: "feature_disabled", feature: Lab::Gate::QC_KEY }, status: :forbidden
      end
    end
  end
end
