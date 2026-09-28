class Admin::Api::ConversationsController < Admin::Api::BaseController
  def show
    data = Admin::ConversationsQuery.call(period: period, filter: neighborhood_filter)
    render_envelope(data, filter: neighborhood_filter)
  end
end
