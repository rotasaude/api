# Conferência da remessa (contrato §4): as lidas seguem em trânsito até a
# decisão (aceite/rejeição), as não lidas viram not_received (a UBS vê).
module Lab
  module ReceiveShipment
    module_function

    def call(shipment:, barcodes:, by:, now: Time.current)
      return Result.fail(:missing_role) unless Access.staff?(by) && Access.member?(by, shipment.exam_provider_id)

      read = Array(barcodes).map(&:to_s).uniq
      ApplicationRecord.transaction do
        shipment.lock!
        next Result.fail(:invalid_transition, details: { status: shipment.status }) unless shipment.status == "sent"

        listed = shipment.samples.order(:id).lock.pluck(:barcode)
        next Result.fail(:invalid_samples) unless (read - listed).empty?

        shipment.samples.where.not(barcode: read).where(status: "in_transit").update_all(status: "not_received", updated_at: now)
        shipment.update!(status: "received", received_by_user: by, received_at: now)
        DomainEvents.publish("lab_shipment.received", lab_shipment_id: shipment.id)
        Result.ok(shipment: shipment)
      end
    end
  end
end
