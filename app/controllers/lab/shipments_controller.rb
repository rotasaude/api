module Lab
  class ShipmentsController < BaseController
    before_action :load_shipment, only: %i[send_out receive]

    def index
      scope = LabShipment.includes(:origin_unit, :exam_provider, :sent_by_user, :received_by_user, samples: :lab_requisition).order(created_at: :desc).limit(100)
      ids = Lab::Access.provider_ids(Current.user)
      if ids.any?
        scope = scope.where(exam_provider_id: params[:provider_id].presence || ids).where(exam_provider_id: ids)
      else
        units = Lab::Access.collecting_unit_ids(Current.user)
        return forbid if units.empty?

        scope = scope.where(origin_unit_id: params[:origin_unit_id].presence || units).where(origin_unit_id: units)
      end
      statuses = Array(params[:status])
      return render(json: { error: "invalid_filter" }, status: :unprocessable_entity) unless (statuses - LabShipment::STATUSES).empty?

      scope = scope.where(status: statuses) if statuses.any?
      render json: { shipments: scope.map { |s| Lab::ShipmentJson.shipment(s) } }
    end

    def create = respond(Lab::CreateShipment.call(body_params, by: Current.user), :created)
    def send_out = respond(Lab::SendShipment.call(shipment: @shipment, by: Current.user), :ok)
    def receive = respond(Lab::ReceiveShipment.call(shipment: @shipment, barcodes: params[:barcodes], by: Current.user), :ok)

    private

    def load_shipment
      @shipment = uuid?(params[:id]) && LabShipment.find_by(id: params[:id])
      not_found unless @shipment
    end

    def respond(result, status)
      return render_failure(result) if result.failure?

      render json: Lab::ShipmentJson.shipment(result.payload[:shipment].reload), status: status
    end
  end
end
