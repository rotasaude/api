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

    # R33: um lote por cidade de cada vez. A chave é fixa porque o semáforo do
    # Solid Queue mora no banco de fila da CIDADE (CityConnection põe o
    # SolidQueue::Record no shard dela; o worker da cidade usa o banco dela) —
    # cidades diferentes nunca disputam o mesmo semáforo. A duração casa com
    # STALE_SENDING: o semáforo nunca vence antes de release_stale! poder
    # devolver linhas de um lote ainda em voo.
    limits_concurrency to: 1, key: "ledi_deliver", duration: STALE_SENDING

    def perform
      city = Current.city
      return unless Platform::Features.usable?(city, :ledi_export)

      LediOutboxEntry.release_stale!(before: STALE_SENDING.ago)
      entries = LediOutboxEntry.claim!(limit: BATCH_SIZE)
      return if entries.empty?

      begin
        Ledi::Delivery.new(city).run(entries)
      ensure
        # R32: o que escapou do caminho por ficha não fica preso em sending
        # (release! só toca linhas ainda sending).
        LediOutboxEntry.release!(entries.map(&:id))
      end
    end
  end
end
