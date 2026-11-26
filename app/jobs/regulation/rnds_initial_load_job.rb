# Carga inicial do envio da regulação à RNDS (módulo 26c; contrato Q7; pré-voo
# M20). Os eventos só criam linha para pedidos vivos; quem já existia quando o
# interruptor `rnds_regulation` ligou entra por aqui: os não terminais (fora do
# rascunho) e os terminais cuja ÚLTIMA linha terminal do andamento é de até
# INITIAL_LOAD_DAYS dias (não o `updated_at`, que qualquer ajuste move). Os
# regulados pelo estado só com `send_external`.
#
# Sem estado próprio: a linha existente é a marca de feito (religar depois de
# desligar pega o que nasceu no meio). O ritmo é do envio: o RndsDeliverJob
# (Task 12) manda no máximo INITIAL_RATE_PER_MINUTE linhas `initial_load` por
# execução. Sem credencial as linhas nascem do mesmo jeito; nada sai daqui.
#
# O interruptor é lido fora da transação da cidade; nunca atribui Current.city.
module Regulation
  class RndsInitialLoadJob < ApplicationJob
    prepend EachCityJob

    queue_as :default

    # A duração fica bem acima do orçamento da rodada: duas rodadas nunca se sobrepõem.
    limits_concurrency to: 1, key: "rnds_regulation_initial_load", duration: RndsLimits::BUDGET * 3

    def perform
      return unless RndsGate.enabled?(Current.city) # fora da transação da cidade

      now = Time.current
      settings = RegulationRndsSetting.current
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RndsLimits::BUDGET.to_f
      # Orçamento esgotado: para; a linha existente é a marca de feito, a
      # próxima rodada (5 min) segue de onde esta parou.
      candidates(now, settings).find_each do |request|
        break if expired?(deadline)

        load!(request, now, settings)
      end
    end

    private

    def expired?(deadline) = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    # Um pedido que falha não trava os demais; o log só tem id e classe (§9).
    def load!(request, now, settings)
      RndsSync.recompute!(request, create: true, initial_load: true, now: now, settings: settings)
    rescue ActiveRecord::RecordNotUnique
      nil # outra rodada criou a linha deste pedido
    rescue StandardError => e
      Rails.logger.error("[Regulation::RndsInitialLoadJob] regulation_request_id=#{request.id} #{e.class.name}")
    end

    def candidates(now, settings)
      terminal = CareRegulation::Catalog::TERMINAL_STATUSES
      recent = RegulationRequestEvent.where(status: terminal).group(:regulation_request_id)
                                     .having("MAX(created_at) >= ?", now - RndsLimits::INITIAL_LOAD_DAYS.days)
                                     .select(:regulation_request_id)
      scope = RegulationRequest.where.not(status: "draft").where.not(id: RegulationRndsSync.select(:regulation_request_id))
      scope = scope.where(state_regulated: false) unless settings.send_external
      scope.where.not(status: terminal).or(scope.where(status: terminal, id: recent))
    end
  end
end
