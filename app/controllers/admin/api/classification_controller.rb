class Admin::Api::ClassificationController < Admin::Api::BaseController
  def show
    data = Admin::ClassificationQuery.call(municipality: current_municipality, period: period)
    render_envelope(data)
  end
end
