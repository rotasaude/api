module Lab
  module SendShipment
    module_function

    def call(shipment:, by:, now: Time.current)
      return Result.fail(:missing_role) unless Access.collecting_unit_ids(by).include?(shipment.origin_unit_id)

      ApplicationRecord.transaction do
        shipment.lock!
        next Result.fail(:invalid_transition, details: { status: shipment.status }) unless shipment.status == "open"

        shipment.update!(status: "sent", sent_by_user: by, sent_at: now)
        shipment.samples.order(:id).lock.pluck(:id)
        shipment.samples.update_all(status: "in_transit", updated_at: now)
        DomainEvents.publish("lab_shipment.sent", lab_shipment_id: shipment.id)
        Result.ok(shipment: shipment)
      end
    end
  end
end
