class Admin::Api::HealthController < Admin::Api::BaseController
  def show
    render_envelope(Admin::HealthQuery.call(municipality: current_municipality))
  end
end
