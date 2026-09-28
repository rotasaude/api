class Admin::Api::ClassificationController < Admin::Api::BaseController
  def show
    data = Admin::ClassificationQuery.call(period: period, filter: neighborhood_filter)
    render_envelope(data, filter: neighborhood_filter)
  end
end
