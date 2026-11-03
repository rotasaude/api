# Consumidor de tfd.leg_done e tfd.allowances_calculated (ADR 0048; §14
# T11): os dois levam tfd_leg_id; as ajudas desse trecho viram linhas BPA
# (Billing::FromTfd, idempotente por ajuda). Roda na transação da cidade
# (IdempotentConsumer); o portão lê só a plataforma (Billing::Gate).
# Desligado no momento do evento: nada (sem retroativo), como o laboratório.
# Sem a unidade de faturamento (FromTfd::BillingUnitMissing; Task 13 I2): o
# handle levanta, a transação da cidade desfaz o ProcessedEvent e o retry_on
# reenfileira o MESMO evento, com espera crescente, até RETRY_ATTEMPTS
# execuções (~11 h no total; FW9) — o padrão do NotifyCitizenJob. Esgotadas,
# a falha fica nas do Solid Queue (visível) e o evento segue pendente; nunca
# um laço sem fim nem um log por minuto. O retorno é o do FromTfd
# ({ created:, skipped: }).
module Billing
  class TfdProductionJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    RETRY_ATTEMPTS = 12

    retry_on FromTfd::BillingUnitMissing, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS

    def handle(tfd_leg_id:, **)
      return unless Gate.enabled?(Current.city)

      FromTfd.call(TfdAllowance.where(tfd_leg_id: tfd_leg_id))
    end
  end
end
