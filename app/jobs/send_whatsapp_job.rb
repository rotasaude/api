# Envio de mensagem para o WhatsApp Cloud API. HTTP fora do lock — ver ADR-0014.
# Não é consumidor de evento; enfileirado direto por outros jobs/services.
# ADR-0020: scoped por município. Corpo final restaurado no Phase 5.
class SendWhatsappJob < ApplicationJob
  include TenantScopedJob
  queue_as :realtime
  retry_on Net::HTTPError, attempts: 5, wait: :polynomially_longer
  retry_on Net::OpenTimeout, attempts: 5, wait: :polynomially_longer

  def perform(to:, body:, municipality_id:)
    with_tenant(municipality_id) do
      # Stub. Implementação completa volta no Phase 5 (precisa de MunicipalityChannel).
      Rails.logger.info("[SendWhatsappJob] to=#{to} muni=#{municipality_id}")
    end
  end

  # Pre-Phase 5 body, preservado aqui para referência. NÃO está em uso.
  # def perform_original(to:, template:, context: {})
  #   idempotency_key = Digest::SHA256.hexdigest([to, template, context].to_json)
  #
  #   result = Whatsapp::Outbound.deliver_template(
  #     to: to,
  #     template: template,
  #     idempotency_key: idempotency_key
  #   )
  #
  #   OutboundMessage.create!(
  #     to: to,
  #     template: template,
  #     idempotency_key: idempotency_key,
  #     status: result.status,
  #     response: result.body,
  #     context: context
  #   )
  # end
end
