class Admin::Api::OverviewController < Admin::Api::BaseController
  def show
    data = Admin::OverviewQuery.call(period: period, filter: neighborhood_filter)
    render_envelope(data, filter: neighborhood_filter)
  end
end
