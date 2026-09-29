# Cria o rascunho (spec 2026-09-29 §6.1). Título/texto conferidos antes do
# público: a resposta traz um código só. Reasons: :invalid_campaign,
# :invalid_audience (details: { details: [{ path:, message: }] }).
module Campaigns
  class Create
    def self.call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      content = ContentValidation.errors(attrs, required: true)
      return Result.fail(:invalid_campaign, details: { details: content }) if content.any?

      audience = AudienceValidation.errors(attrs["audience"])
      return Result.fail(:invalid_audience, details: { details: audience }) if audience.any?

      campaign = ApplicationRecord.transaction do
        Campaign.create!(title: attrs["title"], body: attrs["body"], created_by_user: by,
                         audience: AudienceSchema.normalize(attrs["audience"])).tap do |created|
          DomainEvents.publish("campaign.created", campaign_id: created.id, by_user_id: by.id)
        end
      end
      Result.ok(campaign: campaign)
    end
  end
end
