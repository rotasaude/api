class Admin::Api::ClassificationController < Admin::Api::BaseController
  def show
    data = Admin::ClassificationQuery.call(period: period)
    render_envelope(data)
  end
end
