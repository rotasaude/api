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
      uri = URI("#{GRAPH}/#{@channel.phone_number_id}/messages")
      req = Net::HTTP::Post.new(uri,
        "Authorization" => "Bearer #{@channel.access_token}",
        "Content-Type"  => "application/json"
      )
      req.body = { messaging_product: "whatsapp", to: to, type: "text", text: { body: body } }.to_json
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      Result.new(status: response.code.to_i, body: response.body.to_s)
    end
  end
end
