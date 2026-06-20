class Admin::Api::ConversationsController < Admin::Api::BaseController
  def show
    data = Admin::ConversationsQuery.call(municipality: current_municipality, period: period)
    render_envelope(data)
  end
end
