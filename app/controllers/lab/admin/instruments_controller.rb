# /lab/admin/instruments (contrato §2; F-21.25): municipal_admin, step-up nas escritas; C13 como em /lab/instruments.
# D1: before_action comum (nunca prepend_before_action, que rodaria antes do within_city).
module Lab
  module Admin
    class InstrumentsController < BaseController
      before_action do
        next if Lab::Gate.instruments_usable?(Current.city)

        render json: { error: "feature_disabled", feature: Lab::Gate::QC_KEY }, status: :forbidden
      end
      before_action :admin_provider!, only: :index
      before_action :load_instrument, only: :update

      def index
        render json: { instruments: LabInstrument.where(exam_provider_id: @provider.id).order(:name).map { |i| Lab::AdminJson.instrument(i) } }
      end

      def create = respond(Lab::SaveInstrument.call(body_params), :created)
      def update = respond(Lab::SaveInstrument.call(body_params, instrument: @instrument), :ok)

      private

      def respond(result, status)
        return render_failure(result) if result.failure?

        render json: Lab::AdminJson.instrument(result.payload[:instrument]), status: status
      end

      def load_instrument
        @instrument = uuid?(params[:id]) && LabInstrument.find_by(id: params[:id])
        not_found unless @instrument
      end
    end
  end
end
