# Cliente HTTP para o WhatsApp Cloud API. Chamado SEM transação aberta.
# Ver ADR-0014. Idempotency key vai no payload pra Meta deduplicar do lado dela.
module Whatsapp
  module Outbound
    Result = Struct.new(:status, :body, keyword_init: true)

    API_VERSION = "v22.0"

    def self.deliver_template(to:, template:, idempotency_key:)
      phone_number_id = ENV.fetch("WHATSAPP_PHONE_NUMBER_ID")
      uri = URI("https://graph.facebook.com/#{API_VERSION}/#{phone_number_id}/messages")

      body = {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: to,
        type: "template",
        template: template,
        biz_opaque_callback_data: idempotency_key
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{ENV.fetch("WHATSAPP_ACCESS_TOKEN")}"
      request["Content-Type"] = "application/json"
      request["X-Idempotency-Key"] = idempotency_key
      request.body = body.to_json

      response = http.request(request)
      Result.new(status: response.code.to_i, body: response.body)
    end

    # Envio de texto livre — usado fora do fluxo de template (raro).
    def self.deliver_text(to:, text:, idempotency_key:)
      deliver_template(
        to: to,
        template: { name: "plain", language: { code: "pt_BR" }, components: [{ type: "body", parameters: [{ type: "text", text: text }] }] },
        idempotency_key: idempotency_key
      )
    end
  end
end
