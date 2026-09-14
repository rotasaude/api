class Admin::Api::IngestionController < Admin::Api::BaseController
  def show
    data = Admin::IngestionQuery.call(period: period)
    render_envelope(data)
  end
end
