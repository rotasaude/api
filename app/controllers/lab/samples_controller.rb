module Lab
  class SamplesController < BaseController
    def collect
      sample = find_sample
      return not_found unless sample

      respond(Lab::CollectSample.call(sample: sample, by: Current.user, collected_at: params[:collected_at]), sample)
    end

    def receive
      result = Lab::ReceiveSample.call(barcode: params[:barcode], decision: params[:decision], reason_id: params[:reason_id],
                                       restriction_note: params[:restriction_note], by: Current.user)
      return render_failure(result) if result.failure?

      sample = result.payload[:sample].reload
      render json: { sample: Lab::Json.sample(sample).merge(requisition_number: sample.lab_requisition.number),
                     recollection: result.payload[:recollection] && Lab::Json.sample(result.payload[:recollection]) }
    end

    # Dashboard D5: recoletas a coletar e amostras não recebidas da UBS.
    def pending
      unit_id = params[:origin_unit_id]
      return render(json: { error: "filter_required" }, status: :unprocessable_entity) unless uuid?(unit_id)
      return forbid("not_unit_staff") unless Lab::Access.collecting_unit_ids(Current.user).include?(unit_id) || Lab::Access.provider_ids(Current.user).any?

      base = LabSample.joins(:lab_requisition).where(lab_requisitions: { origin_unit_id: unit_id }).includes(lab_requisition: :patient)
      render json: { recollections: base.where(status: "awaiting").where.not(recollection_of_id: nil).map { |s| Lab::ShipmentJson.pending(s) },
                     not_received: base.where(status: "not_received").map { |s| Lab::ShipmentJson.pending(s) } }
    end

    private

    def find_sample
      if params[:id]
        uuid?(params[:id]) && LabSample.find_by(id: params[:id])
      else
        params[:barcode].is_a?(String) && LabSample.find_by(barcode: params[:barcode])
      end
    end

    def respond(result, sample)
      return render_failure(result) if result.failure?

      sample = result.payload[:sample] || sample
      render json: Lab::Json.sample(sample.reload).merge(requisition_number: sample.lab_requisition.number)
    end
  end
end
