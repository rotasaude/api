# Função pura: payload bruto do WhatsApp -> lista de mensagens normalizadas.
# Não toca AR, não loga, não enfileira. Ver ADR-0010.
module Whatsapp
  module Ingest
    def self.parse(payload)
      return [] unless payload.is_a?(Hash)

      Array(payload["entry"]).flat_map do |entry|
        Array(entry["changes"]).flat_map do |change|
          messages = change.dig("value", "messages") || []
          messages.map { |m| normalize(m) }
        end
      end.compact
    end

    def self.normalize(message)
      return nil unless message.is_a?(Hash) && message["id"]

      {
        message_id: message["id"],
        from: message["from"],
        kind: message["type"],
        body: extract_body(message),
        timestamp: message["timestamp"]
      }
    end

    def self.extract_body(message)
      case message["type"]
      when "text"        then message.dig("text", "body")
      when "button"      then message.dig("button", "payload")
      when "interactive" then message.dig("interactive", "button_reply", "id") ||
                              message.dig("interactive", "list_reply", "id")
      end
    end
  end
end
