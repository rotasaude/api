module Lab
  module Admin
    class RejectionReasonsController < BaseController
      before_action :admin_provider!, only: %i[index create]

      def index
        render json: { reasons: LabRejectionReason.where(exam_provider_id: @provider.id).order(:name).map { |r| Lab::AdminJson.reason(r) } }
      end

      def create = save(Lab::SaveRejectionReason.call(body_params), :created)

      def update
        reason = uuid?(params[:id]) && LabRejectionReason.find_by(id: params[:id])
        return not_found unless reason

        save(Lab::SaveRejectionReason.call(body_params, reason: reason), :ok)
      end

      private

      def save(result, status)
        return render_failure(result) if result.failure?

        render json: Lab::AdminJson.reason(result.payload[:reason]), status: status
      end
    end
  end
end
