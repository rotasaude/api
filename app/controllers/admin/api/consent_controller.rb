class Admin::Api::ConsentController < Admin::Api::BaseController
  def show
    data = Admin::ConsentQuery.call(municipality: current_municipality, period: period)
    render_envelope(data)
  end
end
