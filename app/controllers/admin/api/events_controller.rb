class Admin::Api::EventsController < Admin::Api::BaseController
  def show
    data = Admin::EventsQuery.call(
      name: params[:name],
      from: params[:from],
      to:   params[:to],
      period: period
    )
    render_envelope(data)
  end
end
