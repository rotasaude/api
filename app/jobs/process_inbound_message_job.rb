# Consumo de mensagem WhatsApp inbound. Trabalho transacional do lado do domínio.
# ADR-0020: scoped por município (resolvido na ingestão WhatsApp — Phase 5).
# Já não é consumer de DomainEvents — invocado direto pelo Whatsapp::Ingest.call.
class ProcessInboundMessageJob < ApplicationJob
  include TenantScopedJob
  queue_as :realtime

  def perform(inbound_message_id, municipality_id:)
    with_tenant(municipality_id) do
      # Stub. Corpo final no Phase 5 (avança conversa, gera triagem).
      inbound = InboundMessage.find(inbound_message_id)
      Rails.logger.info("[ProcessInboundMessageJob] received #{inbound.id} for #{municipality_id}")
    end
  end
end
