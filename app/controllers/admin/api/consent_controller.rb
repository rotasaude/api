class Admin::Api::ConsentController < Admin::Api::BaseController
  def show
    data = Admin::ConsentQuery.call(period: period)
    render_envelope(data)
  end
end
