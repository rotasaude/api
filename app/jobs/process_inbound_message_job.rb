# Avança a conversa quando uma mensagem nova chega (ADR-0010/0014/0020/0021).
class ProcessInboundMessageJob < ApplicationJob
  include TenantScopedJob

  def perform(inbound_message_id, municipality_id:)
    with_tenant(municipality_id) do
      inbound = InboundMessage.find(inbound_message_id)
      conversation = Conversation.for(inbound.from, municipality_id: municipality_id)
      conversation.with_lock do
        # Política e maquina de estado da conversa vivem no domínio (ADR-0012).
        # Aqui só garantimos o tenant scoping e o lock.
        result = ConversationAdvance.call(conversation: conversation, inbound: inbound) if defined?(ConversationAdvance)
        SendWhatsappJob.perform_later(to: inbound.from, message: result.reply.to_h, municipality_id: municipality_id) if result&.reply
      end
    end
  end
end
