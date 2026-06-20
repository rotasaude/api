class Admin::Api::IngestionController < Admin::Api::BaseController
  def show
    data = Admin::IngestionQuery.call(municipality: current_municipality, period: period)
    render_envelope(data)
  end
end
