# Cancelar (§5.1): draft ou scheduled → cancelled, final. Quem pega a linha
# primeiro vence o DueJob (FOR UPDATE × SKIP LOCKED). Reason: :invalid_transition.
module Campaigns
  class Cancel
    def self.call(campaign:, by:)
      ApplicationRecord.transaction do
        campaign.lock!
        next Result.fail(:invalid_transition) unless %w[draft scheduled].include?(campaign.status)

        from = campaign.status
        campaign.update!(status: "cancelled", cancelled_by_user: by, cancelled_at: Time.current)
        DomainEvents.publish("campaign.cancelled", campaign_id: campaign.id, from_status: from, by_user_id: by.id)
        Result.ok(campaign: campaign)
      end
    end
  end
end
