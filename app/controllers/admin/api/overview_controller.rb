class Admin::Api::OverviewController < Admin::Api::BaseController
  def show
    data = Admin::OverviewQuery.call(period: period)
    render_envelope(data)
  end
end
