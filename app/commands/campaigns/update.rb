# Edita o rascunho: só draft, só as chaves presentes (title, body, audience).
# Reasons: :not_editable, :invalid_campaign, :invalid_audience.
module Campaigns
  class Update
    FIELDS = %w[title body audience].freeze

    def self.call(campaign:, attrs:)
      attrs = attrs.to_h.stringify_keys.slice(*FIELDS)
      # O40: o interruptor é lido fora da transação da cidade.
      vaccination = attrs.key?("audience") ? AudienceValidation.vaccination_usable?(attrs["audience"]) : false
      ApplicationRecord.transaction do
        campaign.lock!
        next Result.fail(:not_editable) unless campaign.status == "draft"

        content = ContentValidation.errors(attrs)
        next Result.fail(:invalid_campaign, details: { details: content }) if content.any?

        if attrs.key?("audience")
          audience = AudienceValidation.errors(attrs["audience"], vaccination: vaccination)
          next AudienceValidation.failure(audience) if audience.any?

          attrs["audience"] = AudienceSchema.normalize(attrs["audience"])
        end
        campaign.update!(attrs)
        Result.ok(campaign: campaign)
      end
    end
  end
end
