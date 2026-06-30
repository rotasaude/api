# Avança a conversa quando uma mensagem nova chega (ADR-0010/0014/0020/0021).
class ProcessInboundMessageJob < ApplicationJob
  include TenantScopedJob

  def perform(inbound_message_id, municipality_id:)
    with_tenant(municipality_id) do
      inbound = InboundMessage.find(inbound_message_id)
      conversation = Conversation.for(inbound.from, municipality_id: municipality_id)
      conversation.with_lock do
        next if inbound.reload.processed_at?

        result = ConversationAdvance.call(conversation: conversation, inbound: inbound)
        if result&.reply
          SendWhatsappJob.perform_later(
            to: inbound.from, message: result.reply.to_h, municipality_id: municipality_id
          )
        end
        inbound.update!(processed_at: Time.current)
      end
    end
  end
end
