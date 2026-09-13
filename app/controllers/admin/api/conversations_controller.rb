class Admin::Api::ConversationsController < Admin::Api::BaseController
  def show
    data = Admin::ConversationsQuery.call(period: period)
    render_envelope(data)
  end
end
