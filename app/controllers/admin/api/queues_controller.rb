# Queues: lê a fila compartilhada — o Solid Queue só vai para o banco da cidade
# no Plano 5, então este painel ainda mostra a fila de todas as cidades.
# A ressalva do bug de idempotência (§5 / §6.1) é visualizada no centro
# de notificações do frontend — não duplicar texto aqui.
class Admin::Api::QueuesController < Admin::Api::BaseController
  def show
    render_envelope(Admin::QueuesQuery.call)
  end
end
