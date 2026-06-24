# Rede de segurança: re-enfileira AlertMunicipalityJob para eventos
# triage.urgent com published_at IS NULL. Roda a cada 5min (recurring.yml).
# Idempotência por consumidor (ADR-0005) garante que duplicatas sumam.
class ResendPendingAlertsJob < ApplicationJob
  prepend AdminRoleJob
  queue_as :urgent

  def perform
    DomainEvent.pending.where(name: "triage.urgent").find_each do |event|
      Events.redispatch(event)
    end
  end
end
