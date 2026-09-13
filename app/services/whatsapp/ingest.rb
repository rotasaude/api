# Entrada de ingestão do WhatsApp (ADR-0007). O webhook chega SEM cidade no host.
#   Whatsapp::Ingest.call(payload)  # roteia, persiste, enfileira
# HMAC já foi validado pelo controller antes (ADR-0007).
#
# Roteamento (spec banco-por-cidade §2): phone_number_id → CityChannel no
# catálogo de PLATAFORMA → City. Só então abre a conexão daquela cidade e grava
# a mensagem no banco DELA. Conteúdo de mensagem nunca toca a plataforma — o
# UnknownChannel guarda só metadado de roteamento (Ruling R17).
module Whatsapp
  module Ingest
    def self.call(payload)
      changes_in(payload).each do |change|
        pnid = change.dig("value", "metadata", "phone_number_id")
        city = route(pnid, change)
        next unless city

        messages_in(change).each do |msg|
          ingest_message(msg, city: city)
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

      channel = CityChannel.active.find_by(phone_number_id: phone_number_id)
      if channel.nil?
        UnknownChannel.record!(phone_number_id: phone_number_id, change: change)
        return nil
      end

      city = channel.city
      return city if city.servable?

      # Canal conhecido de cidade não servível (provisioning/suspended/archived):
      # falha fechada, como CityScopedJob#with_city — nada é gravado no banco de
      # uma cidade fora do ar. Não é canal desconhecido, então não vai para
      # UnknownChannel.
      Rails.logger.warn(
        "[whatsapp.ingest] phone_number_id=#{phone_number_id} city=#{city.slug} " \
        "status=#{city.status}: cidade não servível, mensagens descartadas"
      )
      nil
    end

    def self.ingest_message(msg, city:)
      normalized = Parser.normalize(msg) or return

      Current.set(city: city) do
        CityConnection.with(city) do
          ApplicationRecord.transaction do
            inbound = InboundMessage.create!(
              message_id: normalized[:message_id],
              from: normalized[:from],
              kind: normalized[:kind] || "unknown",
              raw: msg.to_json
            )
            ProcessInboundMessageJob.perform_later(inbound.id, city_slug: city.slug)
          end
        end
      end
    rescue ActiveRecord::RecordNotUnique
      # reentrega do mesmo wamid via DB constraint — já ingerido, no-op
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.where(:message_id, :taken).any?
      # reentrega do mesmo wamid via Rails validation — já ingerido, no-op
    end
  end
end
