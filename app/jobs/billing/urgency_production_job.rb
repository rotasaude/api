# Consumidor de urgency.encounter_closed e urgency.patient_identified (ADR
# 0050; contrato §9 e §14 Q12): os dois levam encounter_id; o encontro
# fechado vira as linhas do BPA (Billing::FromUrgency, idempotente pelos
# códigos do encontro). No fechamento do provisório não identificado nada é
# gravado (a pendência sem linha); a identificação, mesmo dias depois, grava
# no paciente real. Roda na transação da cidade (IdempotentConsumer); o portão
# lê só a plataforma (Billing::Gate). Desligado no momento do evento: nada
# (sem retroativo), como o laboratório, o TFD e o CAPS.
module Billing
  class UrgencyProductionJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(encounter_id:, **)
      return unless Gate.enabled?(Current.city)

      encounter = UrgencyEncounter.find_by(id: encounter_id)
      encounter && FromUrgency.call(encounter)
    end
  end
end
