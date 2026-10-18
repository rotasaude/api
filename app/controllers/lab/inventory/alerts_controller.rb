# GET /lab/inventory/alerts (contrato §5): contador do painel — sem trilha
# (nenhum evento, nenhuma auditoria), para membros e admin.
module Lab
  module Inventory
    class AlertsController < BaseController
      before_action -> { provider! }

      def show = render(json: Alerts.call(provider_id: @provider.id))
    end
  end
end
