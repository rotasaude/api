# Envio contínuo das doses à RNDS (ADR 0047, Desvio 12). Recorrente a cada
# minuto; no worker de cada cidade roda só nela (EachCityJob). Sem argumentos:
# nada de credencial nem dose na fila do Solid Queue. Só roda com
# `rnds_immunization` UTILIZÁVEL (ligado, `vaccination`, credencial ok e, fora
# de dev/test/staging, catálogo revisado).
module Rnds
  class DeliverJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    BATCH_SIZE = 20
    STALE_SENDING = 10.minutes

    # Um lote por cidade de cada vez: a chave é fixa porque o semáforo do
    # Solid Queue mora no banco de fila da CIDADE. A duração casa com
    # STALE_SENDING (o semáforo nunca vence antes de release_stale! poder
    # devolver linhas de um lote em voo).
    limits_concurrency to: 1, key: "rnds_deliver", duration: STALE_SENDING

    def perform
      city = Current.city
      return unless Rnds::Gate.usable?(city) # interruptores: fora da transação da cidade

      RndsOutboxEntry.release_stale!(before: STALE_SENDING.ago)
      entries = RndsOutboxEntry.claim!(limit: BATCH_SIZE)
      return if entries.empty?

      token = entries.first.last_attempted_at # posse do lote (RndsOutboxEntry.claim!)
      begin
        Rnds::Delivery.new(city).run(entries)
      rescue Rnds::Errors::NotConfigured => e
        # URL da plataforma ausente: nada sai, nada conta tentativa; o prazo segue correndo.
        Rails.logger.warn("[Rnds::DeliverJob] city=#{city.slug} #{e.class.name}")
      ensure
        # O que escapou do caminho por entrada não fica preso em sending.
        RndsOutboxEntry.release!(entries.map(&:id), token: token)
      end
    end
  end
end
