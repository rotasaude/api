class Admin::Api::HealthController < Admin::Api::BaseController
  def show
    render_envelope(Admin::HealthQuery.call)
  end
end
