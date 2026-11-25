# Envio dos lotes ao SI-BNAFAR (módulo 27b; contrato §3; R31). Recorrente a
# cada 5 minutos; no worker de cada cidade roda só nela (EachCityJob). Sem
# argumentos: nada de credencial nem payload na fila do Solid Queue. Só roda
# com o `bnafar` UTILIZÁVEL (R31): desligado, ou com a credencial do ambiente
# recusada, o lote `queued` espera a religação ou a credencial nova.
module Bnafar
  class DeliverJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    BATCH_LIMIT = 10

    # Um envio por cidade de cada vez: a chave é fixa porque o semáforo do
    # Solid Queue mora no banco de fila da CIDADE. A duração casa com
    # STALE_SENDING (o semáforo nunca vence antes de release_stale! poder
    # devolver um lote em voo).
    limits_concurrency to: 1, key: "bnafar_deliver", duration: Limits::STALE_SENDING

    def perform
      city = Current.city
      return unless Bnafar::Gate.usable?(city) # interruptores: fora da transação da cidade

      environment = Bnafar::Environment.current
      BnafarBatch.release_stale!(before: Limits::STALE_SENDING.ago)
      batches = BnafarBatch.claim!(limit: BATCH_LIMIT, environment: environment)
      return if batches.empty?

      token = batches.first.last_attempted_at # posse do lote (BnafarBatch.claim!)
      begin
        Delivery.new(city, environment: environment).run(batches)
      rescue Errors::NotConfigured => e
        # URL da plataforma ou credencial ausentes: nada sai, nada conta tentativa.
        Rails.logger.warn("[Bnafar::DeliverJob] city=#{city.slug} #{e.class.name}")
      ensure
        # O que escapou do caminho por lote não fica preso em sending.
        BnafarBatch.release!(batches.map(&:id), token: token)
      end
    end
  end
end
