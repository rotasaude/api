# Webhook do WhatsApp Cloud API. Ver ADR-0010.
# Caminho crítico: HMAC -> dedup -> persist -> publish -> 200 OK em ~50ms.
module Webhooks
  class WhatsappController < ApplicationController
    # TODO: reativar quando Phase 4 setar current_municipality
    skip_tenant_scope

    skip_before_action :verify_authenticity_token, raise: false
    before_action :verify_signature!, only: :create

    # GET — handshake de verificação da Meta.
    def verify
      expected = ENV.fetch("WHATSAPP_VERIFY_TOKEN")
      provided = params["hub.verify_token"].to_s

      if ActiveSupport::SecurityUtils.secure_compare(expected, provided)
        render plain: params["hub.challenge"].to_s
      else
        head :forbidden
      end
    end

    # POST — entrega de evento (mensagem, status, leitura).
    def create
      messages = Whatsapp::Ingest.parse(payload)

      messages.each do |message|
        ApplicationRecord.transaction do
          # Dedup na borda (ADR-0005): se a mesma message_id chegar de novo,
          # cai na constraint única e a transação aborta — pulamos pra próxima.
          ProcessedEvent.create!(
            consumer: "whatsapp_webhook",
            event_id: message[:message_id],
            processed_at: Time.current
          )

          inbound = InboundMessage.create!(
            message_id: message[:message_id],
            from: message[:from],
            kind: message[:kind],
            raw: payload    # criptografado em repouso — ADR-0011
          )

          DomainEvents.publish("inbound_message.received", inbound_message_id: inbound.id, message_id: message[:message_id], from: message[:from])
        end
      rescue ActiveRecord::RecordNotUnique
        Rails.logger.info("[whatsapp] dup message_id=#{message[:message_id]}")
      end

      head :ok
    end

    private

    def payload
      @payload ||= JSON.parse(request.raw_post)
    rescue JSON::ParserError
      {}
    end

    def verify_signature!
      raw = request.raw_post
      header = request.headers["X-Hub-Signature-256"].to_s
      expected = "sha256=" + OpenSSL::HMAC.hexdigest(
        "sha256", ENV.fetch("WHATSAPP_APP_SECRET"), raw
      )

      return if ActiveSupport::SecurityUtils.secure_compare(expected, header)
      head :unauthorized
    end
  end
end
