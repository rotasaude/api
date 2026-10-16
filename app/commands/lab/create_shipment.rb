# Remessa da UBS (spec §5.3): amostras coletadas, da unidade, do laboratório,
# com coleta na unidade e fora de outra remessa; temperatura -30..60 °C.
module Lab
  module CreateShipment
    MAX = 200

    module_function

    def call(params, by:)
      p = params.to_h.stringify_keys
      unit = p["origin_unit_id"].is_a?(String) && HealthUnit.find_by(id: p["origin_unit_id"])
      return Result.fail(:not_found) unless unit
      return Result.fail(:missing_role) unless Access.collecting_unit_ids(by).include?(unit.id)

      provider = p["provider_id"].is_a?(String) && Access.labs.find_by(id: p["provider_id"])
      return Result.fail(:invalid_provider) unless provider

      temperature = p["temperature_celsius"]
      return Result.fail(:invalid_temperature) unless temperature.is_a?(Numeric) && temperature.between?(-30, 60)

      return Result.fail(:unit_does_not_collect) unless unit.collects_samples

      barcodes = Array(p["barcodes"]).map(&:to_s).uniq
      return Result.fail(:shipment_empty) if barcodes.empty?
      return Result.fail(:invalid_samples) if barcodes.size > MAX

      ApplicationRecord.transaction do
        samples = LabSample.lock.includes(:lab_requisition).where(barcode: barcodes).order(:id).index_by(&:barcode)
        # Dashboard D4: a recusa diz QUAL amostra (código de barras no corpo).
        failure = barcodes.lazy.map { |code| problem(samples[code], code, unit, provider) }.find(&:itself)
        next failure if failure

        samples = samples.values

        shipment = LabShipment.create!(origin_unit: unit, exam_provider: provider, temperature_celsius: temperature, created_by_user: by)
        LabSample.where(id: samples.map(&:id)).update_all(lab_shipment_id: shipment.id, updated_at: Time.current)
        Result.ok(shipment: shipment)
      end
    end

    def problem(sample, code, unit, provider)
      req = sample&.lab_requisition
      if sample.nil? || req.origin_unit_id != unit.id || req.exam_provider_id != provider.id || req.collection_place != "ubs"
        return Result.fail(:wrong_origin_unit, details: { barcode: code })
      end
      return Result.fail(:sample_in_other_shipment, details: { barcode: code }) if sample.lab_shipment_id
      return Result.fail(:sample_not_collected, details: { barcode: code }) unless sample.status == "awaiting" && sample.collected?

      nil
    end
    private_class_method :problem
  end
end
