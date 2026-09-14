# Avança a conversa quando uma mensagem nova chega (ADR-0007/0005), na cidade
# dona do canal — city_slug vem do Whatsapp::Ingest.
class ProcessInboundMessageJob < ApplicationJob
  include CityScopedJob

  def perform(inbound_message_id, city_slug:)
    with_city(city_slug) do
      inbound = InboundMessage.find(inbound_message_id)
      conversation = Conversation.for(inbound.from)
      conversation.with_lock do
        next if inbound.reload.processed_at?

        result = ConversationAdvance.call(conversation: conversation, inbound: inbound)
        if result&.reply
          SendWhatsappJob.perform_later(
            to: inbound.from, message: result.reply.to_h, city_slug: city_slug
          )
        end
        inbound.update!(processed_at: Time.current)
      end
    end
  end
end
