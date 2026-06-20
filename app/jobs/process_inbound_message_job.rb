# Consome inbound_message.received. Trabalho transacional do lado do domínio.
# HTTP de resposta vai por SendWhatsappJob — ver ADR-0014.
class ProcessInboundMessageJob < ApplicationJob
  include IdempotentConsumer
  queue_as :realtime

  def consume(event)
    inbound = InboundMessage.find(event.aggregate_id)
    conversation = Conversation.for_phone(inbound.from)
    parsed = Whatsapp::Ingest.normalize(JSON.parse(inbound.raw)) rescue nil

    return unless parsed && conversation.active?

    answer = parsed[:body]
    triagem = conversation.current_triagem || conversation.start_triagem!

    outcome = triagem.record_answer!(answer)

    # NÃO chamamos a Cloud API daqui — só enfileiramos o envio (ADR-0014).
    SendWhatsappJob.perform_later(
      to: inbound.from,
      template: triagem.next_prompt_template(outcome),
      context: { triagem_id: triagem.id }
    )
  end
end
