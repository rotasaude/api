# Queues: cross-tenant por natureza (Solid Queue não conhece muni).
# A ressalva do bug de idempotência (§5 / §6.1) é visualizada no centro
# de notificações do frontend — não duplicar texto aqui.
class Admin::Api::QueuesController < Admin::Api::BaseController
  def show
    render_envelope(Admin::QueuesQuery.call)
  end
end
