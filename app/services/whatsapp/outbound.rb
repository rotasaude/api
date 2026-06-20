# Cliente WhatsApp Cloud por canal (ADR-0021/0024).
require "net/http"

module Whatsapp
  class Outbound
    GRAPH = "https://graph.facebook.com/v19.0"

    def initialize(channel)
      @channel = channel
    end

    def deliver_text(to:, body:)
      uri = URI("#{GRAPH}/#{@channel.phone_number_id}/messages")
      req = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{@channel.access_token}", "Content-Type" => "application/json")
      req.body = { messaging_product: "whatsapp", to: to, type: "text", text: { body: body } }.to_json
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    end
  end
end
