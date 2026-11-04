# Consumidor de psychosocial.action_recorded (ADR 0049; contrato §8): a ação
# BPA-C/BPA-I do CAPS vira linha do BPA (Billing::FromPsychosocial,
# idempotente por ação; a raas_psi é ignorada lá). Roda na transação da cidade
# (IdempotentConsumer); o portão lê só a plataforma (Billing::Gate).
# Desligado no momento do evento: nada (sem retroativo), como o laboratório e
# o TFD. O cancelamento da ação não tem consumidor: o Psychosocial::CancelAction
# cancela a linha na mesma transação.
module Billing
  class PsychosocialProductionJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(action_id:, **)
      return unless Gate.enabled?(Current.city)

      action = PsychosocialAction.find_by(id: action_id)
      action && FromPsychosocial.call(action)
    end
  end
end
