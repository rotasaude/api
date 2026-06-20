# Entrada de ingestão multi-tenant (ADR-0021).
#   Whatsapp::Ingest.call(payload)  # roteia, persiste, enfileira
# HMAC já foi validado pelo controller antes (ADR-0010).
module Whatsapp
  module Ingest
    def self.call(payload)
      changes_in(payload).each do |change|
        pnid = change.dig("value", "metadata", "phone_number_id")
        municipality_id = route(pnid, change)
        next unless municipality_id

        messages_in(change).each do |msg|
          ingest_message(msg, municipality_id: municipality_id)
        end
      end
    end

    def self.changes_in(payload)
      return [] unless payload.is_a?(Hash)
      Array(payload["entry"]).flat_map { |e| Array(e["changes"]) }
    end

    def self.messages_in(change)
      Array(change.dig("value", "messages"))
    end

    def self.route(phone_number_id, change)
      return nil if phone_number_id.blank?
      channel = ApplicationRecord.connected_to(role: :admin) {
        MunicipalityChannel.active.find_by(phone_number_id: phone_number_id)
      }
      return channel.municipality_id if channel

      UnknownChannel.record!(phone_number_id: phone_number_id, change: change)
      nil
    end

    def self.ingest_message(msg, municipality_id:)
      normalized = Parser.normalize(msg) or return

      ApplicationRecord.transaction do
        Current.municipality_id = municipality_id
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", municipality_id])
        )
        inbound = InboundMessage.create!(
          message_id: normalized[:message_id],
          from: normalized[:from],
          kind: normalized[:kind] || "unknown",
          raw: msg.to_json,
          municipality_id: municipality_id
        )
        ProcessInboundMessageJob.perform_later(inbound.id, municipality_id: municipality_id)
      end
    rescue ActiveRecord::RecordNotUnique
      # reentrega do mesmo wamid via DB constraint — já ingerido, no-op
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.where(:message_id, :taken).any?
      # reentrega do mesmo wamid via Rails validation — já ingerido, no-op
    end
  end
end
