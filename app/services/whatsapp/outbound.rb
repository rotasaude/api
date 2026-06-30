# Cliente WhatsApp Cloud por canal (ADR-0021/0024).
require "net/http"

module Whatsapp
  class Outbound
    GRAPH = "https://graph.facebook.com/v19.0"

    Result = Struct.new(:status, :body, keyword_init: true)

    def initialize(channel)
      @channel = channel
    end

    def deliver_text(to:, body:)
      post({ messaging_product: "whatsapp", to: to, type: "text", text: { body: body } })
    end

    def deliver_interactive(to:, reply:)
      post(interactive_payload(to: to, reply: reply))
    end

    # Corpo da requisição Graph para um Messaging::Reply interativo.
    def interactive_payload(to:, reply:)
      interactive =
        case reply.kind
        when :buttons
          { type: "button", body: { text: reply.body },
            action: { buttons: reply.options.map { |o| { type: "reply", reply: { id: o[:id], title: o[:title] } } } } }
        when :list
          { type: "list", body: { text: reply.body },
            action: { button: I18n.t("whatsapp.list_button"),
                      sections: [{ rows: reply.options.map { |o| { id: o[:id], title: o[:title] } } }] } }
        end
      { messaging_product: "whatsapp", to: to, type: "interactive", interactive: interactive }
    end

    def deliver_template(to:, reply:)
      post(template_payload(to: to, reply: reply))
    end

    # Corpo da requisição Graph para um template aprovado (F-01.7).
    def template_payload(to:, reply:)
      components = reply.params.empty? ? [] :
        [{ type: "body", parameters: reply.params.map { |p| { type: "text", text: p } } }]
      {
        messaging_product: "whatsapp", to: to, type: "template",
        template: { name: reply.name, language: { code: "pt_BR" }, components: components }
      }
    end

    private

    def post(payload)
      uri = URI("#{GRAPH}/#{@channel.phone_number_id}/messages")
      req = Net::HTTP::Post.new(uri,
        "Authorization" => "Bearer #{@channel.access_token}",
        "Content-Type"  => "application/json"
      )
      req.body = payload.to_json
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      Result.new(status: response.code.to_i, body: response.body.to_s)
    end
  end
end
