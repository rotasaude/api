# Envio contínuo das fichas LEDI da cidade (ADR 0028; spec §6.4). Recorrente a
# cada minuto e disparado por Ledi::Enqueue; no worker de cada cidade roda só
# nela (EachCityJob). Sem argumentos: nada de credencial ou ficha na fila do
# Solid Queue. Só roda com ledi_export UTILIZÁVEL (ligado, record_mode != off,
# pec_url, IBGE e credencial ok).
module Ledi
  class DeliverJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    BATCH_SIZE = 20
    STALE_SENDING = 10.minutes

    def perform
      city = Current.city
      return unless Platform::Features.usable?(city, :ledi_export)

      LediOutboxEntry.release_stale!(before: STALE_SENDING.ago)
      entries = LediOutboxEntry.claim!(limit: BATCH_SIZE)
      return if entries.empty?

      Ledi::Delivery.new(city).run(entries)
    end
  end
end
