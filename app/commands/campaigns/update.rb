# Edita o rascunho: só draft, só as chaves presentes (title, body, audience).
# Reasons: :not_editable, :invalid_campaign, :invalid_audience.
module Campaigns
  class Update
    FIELDS = %w[title body audience].freeze

    def self.call(campaign:, attrs:)
      attrs = attrs.to_h.stringify_keys.slice(*FIELDS)
      ApplicationRecord.transaction do
        campaign.lock!
        next Result.fail(:not_editable) unless campaign.status == "draft"

        content = ContentValidation.errors(attrs)
        next Result.fail(:invalid_campaign, details: { details: content }) if content.any?

        if attrs.key?("audience")
          audience = AudienceValidation.errors(attrs["audience"])
          next Result.fail(:invalid_audience, details: { details: audience }) if audience.any?

          attrs["audience"] = AudienceSchema.normalize(attrs["audience"])
        end
        campaign.update!(attrs)
        Result.ok(campaign: campaign)
      end
    end
  end
end
