class Admin::Api::EventsController < Admin::Api::BaseController
  def show
    data = Admin::EventsQuery.call(name: params[:name], period: period)
    render_envelope(data)
  end
end
