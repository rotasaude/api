# Recálculo de todos os pedidos de uma cidade depois de uma mudança dos ajustes
# do envio à RNDS (módulo 26c; revisão final I1; Q26). Mudança de ajuste não é
# mudança do pedido: o que volta à fila vai na faixa da carga inicial
# (`lane: :bulk`), e o terminal com último aceite de mais de INITIAL_LOAD_DAYS
# dias fica de fora (`RndsSync.bulk_requests`). O consumidor
# (RndsSyncJob) só o enfileira, sem argumentos: o recálculo lê o estado atual,
# então é idempotente por construção e dispensa o IdempotentConsumer.
#
# Fora de qualquer transação: cada pedido num `RndsSync.recompute!` próprio (uma
# transação curta, FOR UPDATE só na linha dele), como na carga inicial. Assim o
# envio (RndsDeliverJob) nunca espera por uma transação que trava todas as
# linhas da cidade. Uma linha que falha não para as outras; o log só tem o id e
# a classe (§9).
#
# No worker de cada cidade roda só nela (EachCityJob); o interruptor é lido fora
# da transação da cidade; nunca atribui Current.city.
module Regulation
  class RndsRecomputeAllJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    # Um por cidade de cada vez (o semáforo mora no banco de fila da cidade); o
    # segundo espera e relê o estado atual.
    limits_concurrency to: 1, key: "rnds_regulation_recompute_all", duration: RndsLimits::STALE_SENDING

    def perform
      now = Time.current
      create = RndsGate.enabled?(Current.city) # fora da transação da cidade
      settings = RegulationRndsSetting.current
      RndsSync.bulk_requests(RegulationRequest.where(id: RegulationRndsSync.select(:regulation_request_id)), now: now).find_each do |request|
        recompute(request, create: false, now: now, settings: settings, lane: :bulk)
      end
      return unless create && settings.send_external

      # Com `send_external` ligado agora: os regulados pelo estado não terminais
      # sem linha nascem na faixa da carga inicial (o RndsInitialLoadJob também
      # os acharia; o índice único resolve a corrida).
      RndsSync.uncovered_state_regulated.find_each do |request|
        recompute(request, create: true, initial_load: true, now: now, settings: settings)
      end
    end

    private

    def recompute(request, **)
      RndsSync.recompute!(request, **)
    rescue ActiveRecord::RecordNotUnique
      nil # outra rodada criou a linha deste pedido
    rescue StandardError => e
      Rails.logger.error("[#{self.class.name}] regulation_request_id=#{request.id} #{e.class.name}")
    end
  end
end
