# Consumidor de tfd.leg_done e tfd.allowances_calculated (ADR 0048; §14
# T11): os dois levam tfd_leg_id; as ajudas desse trecho viram linhas BPA
# (Billing::FromTfd, idempotente por ajuda). Roda na transação da cidade
# (IdempotentConsumer); o portão lê só a plataforma (Billing::Gate).
# Desligado no momento do evento: nada (sem retroativo), como o laboratório.
module Billing
  class TfdProductionJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(tfd_leg_id:, **)
      return unless Gate.enabled?(Current.city)

      FromTfd.call(TfdAllowance.where(tfd_leg_id: tfd_leg_id))
    end
  end
end
