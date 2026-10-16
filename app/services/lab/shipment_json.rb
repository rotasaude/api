module Lab
  module ShipmentJson
    module_function

    def shipment(s)
      { id: s.id, origin_unit: { id: s.origin_unit_id, name: s.origin_unit.name },
        provider: { id: s.exam_provider_id, name: s.exam_provider.name }, status: s.status,
        temperature_celsius: s.temperature_celsius&.to_f, sent_at: s.sent_at&.iso8601,
        sent_by: Screenings::Json.staff_name(s.sent_by_user), received_at: s.received_at&.iso8601,
        received_by: Screenings::Json.staff_name(s.received_by_user),
        samples: s.samples.includes(:lab_requisition).order(:barcode).map do |x|
          { id: x.id, barcode: x.barcode, material: x.material, status: x.status, requisition_number: x.lab_requisition.number }
        end }
    end

    def pending(sample)
      req = sample.lab_requisition
      Json.sample(sample).merge(requisition: { id: req.id, number: req.number, patient_display_name: req.patient.display_name })
    end
  end
end
