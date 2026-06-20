# Envio de mensagem para o WhatsApp Cloud API. HTTP fora do lock — ver ADR-0014.
# Não é consumidor de evento; enfileirado direto por outros jobs/services.
# Idempotência via idempotency_key passada à Cloud API (não via processed_events).
class SendWhatsappJob < ApplicationJob
  queue_as :realtime
  retry_on Net::HTTPError, attempts: 5, wait: :polynomially_longer
  retry_on Net::OpenTimeout, attempts: 5, wait: :polynomially_longer

  def perform(to:, template:, context: {})
    idempotency_key = Digest::SHA256.hexdigest([to, template, context].to_json)

    result = Whatsapp::Outbound.deliver_template(
      to: to,
      template: template,
      idempotency_key: idempotency_key
    )

    OutboundMessage.create!(
      to: to,
      template: template,
      idempotency_key: idempotency_key,
      status: result.status,
      response: result.body,
      context: context
    )
  end
end
