# Rede de segurança: re-enfileira AlertMunicipalityJob para eventos
# triagem.urgent com published_at IS NULL. Roda a cada 5min (recurring.yml).
# Idempotência por consumidor (ADR-0005) garante que duplicatas sumam.
class ResendPendingAlertsJob < ApplicationJob
  include AdminRoleJob
  queue_as :urgent

  def perform
    DomainEvent.pending.where(name: "triagem.urgent").find_each do |event|
      Events.redispatch(event)
    end
  end
end
