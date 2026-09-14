class Admin::Api::ProtocolsController < Admin::Api::BaseController
  def index
    data = Admin::ProtocolsQuery.index
    render_envelope(data)
  end

  def show
    data = Admin::ProtocolsQuery.show(id: params[:id])
    return head :not_found unless data
    render_envelope(data)
  end
end
