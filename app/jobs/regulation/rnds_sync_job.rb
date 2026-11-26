# Consumidor dos eventos que mudam o que um pedido de regulação deve ter na
# RNDS (módulo 26c; contrato §2, gatilhos; decisão 15; molde do
# CareRegulation::AppointmentSyncJob). Cada evento só diz QUAIS pedidos olhar
# (Regulation::RndsSync.affected_request_ids); o recálculo lê o estado atual,
# então a ordem e o redespacho não importam. Idempotente por (consumidor,
# evento) no IdempotentConsumer, na transação da cidade.
#
# Cria linha só com o interruptor ligado (`RndsGate.enabled?`, que lê só a
# plataforma) e só pelos eventos de um pedido vivo; a linha existente é sempre
# recalculada, com o interruptor em qualquer estado. Nunca chama a RNDS e
# nunca atribui Current.city.
module Regulation
  class RndsSyncJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    # O payload não diz de que evento veio: o nome fica para o handle.
    def perform(event_name:, **rest)
      @event_name = event_name
      super(event_name: event_name, **rest)
    end

    def handle(**payload)
      now = Time.current
      ids = RndsSync.affected_request_ids(@event_name, payload)
      enabled = RndsGate.enabled?(Current.city)
      return RndsSync.recompute_all!(now: now, create: enabled) if ids == :all

      create = enabled && RndsSync::CREATING_EVENT.match?(@event_name)
      RegulationRequest.where(id: ids).order(:id).each do |request|
        RndsSync.recompute!(request, create: create, now: now)
      end
    end
  end
end
