module Lab
  class SamplesController < BaseController
    def collect
      sample = find_sample
      return not_found unless sample

      respond(Lab::CollectSample.call(sample: sample, by: Current.user, collected_at: params[:collected_at]), sample)
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
