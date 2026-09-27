# Queues: lê o Solid Queue do banco da cidade do host (Plano 5) — só a fila
# desta cidade (queues_query_spec, city_connection_queue_spec).
# A ressalva do bug de idempotência (§5 / §6.1) é visualizada no centro
# de notificações do frontend — não duplicar texto aqui.
class Admin::Api::QueuesController < Admin::Api::BaseController
  def show
    render_envelope(Admin::QueuesQuery.call)
  end
end
