# GET /unknown_channels (F-01.5) — números que chegaram ao webhook sem nenhum
# CityChannel (Whatsapp::Ingest → UnknownChannel.record!), para o operador
# diagnosticar WABA mal configurado.
#
#   → 200 { unknown_channels: [{ phone_number_id, display_phone_number, hits,
#                                first_seen_at, last_seen_at }] }
#
# Mais recente primeiro, no máximo LIMIT linhas. `sample_change` NUNCA sai
# inteiro: só `display_phone_number` é extraído dele (allow-list, como o
# próprio UnknownChannel.redact).
module Operators
  class UnknownChannelsController < BaseController
    LIMIT = 100

    def index
      rows = UnknownChannel.order(last_seen_at: :desc).limit(LIMIT).map do |row|
        sample = row.sample_change.is_a?(Hash) ? row.sample_change : {}
        {
          phone_number_id: row.phone_number_id,
          display_phone_number: sample["display_phone_number"],
          hits: row.hits,
          first_seen_at: row.first_seen_at.iso8601,
          last_seen_at: row.last_seen_at.iso8601
        }
      end
      render json: { unknown_channels: rows }
    end
  end
end
