# Envio contínuo da regulação à RNDS (módulo 26c; contrato §3; Q16, Q17;
# pré-voo I2, I5, I15). Recorrente a cada minuto; no worker de cada cidade
# roda só nela (EachCityJob). Sem argumentos: nada de credencial nem pedido na
# fila do Solid Queue.
#
# Em toda rodada, com o interruptor ligado ou não (Q17, molde do bnafar_daily):
# o payload de TODA remessa com COALESCE(accepted_at, sent_at) anterior a
# PAYLOAD_DAYS dias vira NULL; os metadados ficam. Depois, só com
# `rnds_regulation` UTILIZÁVEL (ligado, regulação, credencial ok, IBGE e UF;
# lido fora da transação da cidade): devolve o `sending` esquecido, reivindica
# até BATCH_SIZE linhas e, depois delas, até INITIAL_RATE_PER_MINUTE da carga
# inicial, e envia. Nunca atribui Current.city.
module Regulation
  class RndsDeliverJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    # Um lote por cidade de cada vez: a chave é fixa porque o semáforo do Solid
    # Queue mora no banco de fila da CIDADE. A duração casa com STALE_SENDING.
    limits_concurrency to: 1, key: "rnds_regulation_deliver", duration: RndsLimits::STALE_SENDING

    def perform
      city = Current.city
      now = Time.current
      purge_payloads!(now)
      return unless RndsGate.usable?(city) # interruptores: fora da transação da cidade

      RegulationRndsSync.release_stale!(before: now - RndsLimits::STALE_SENDING)
      syncs = RegulationRndsSync.claim!(limit: RndsLimits::BATCH_SIZE, initial_limit: RndsLimits::INITIAL_RATE_PER_MINUTE, now: now)
      return if syncs.empty?

      token = syncs.first.claimed_at # posse do lote (RegulationRndsSync.claim!)
      begin
        RndsDelivery.new(city).run(syncs)
      rescue Rnds::Errors::NotConfigured => e
        # URL da plataforma ou credencial ausentes: nada sai, nada conta tentativa.
        Rails.logger.warn("[Regulation::RndsDeliverJob] city=#{city.slug} #{e.class.name}")
      ensure
        # O que escapou do caminho por linha não fica preso em sending.
        RegulationRndsSync.release!(syncs.map(&:id), token: token)
      end
    end

    private

    def purge_payloads!(now)
      RegulationRndsDelivery.where.not(payload: nil)
                            .where("COALESCE(accepted_at, sent_at) < ?", now - RndsLimits::PAYLOAD_DAYS.days)
                            .update_all(payload: nil)
    end
  end
end
