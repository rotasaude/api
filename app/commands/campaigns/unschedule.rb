# Desagendar (§5.1): scheduled → draft, para editar. Reason: :invalid_transition.
module Campaigns
  class Unschedule
    def self.call(campaign:, by:)
      ApplicationRecord.transaction do
        campaign.lock!
        next Result.fail(:invalid_transition) unless campaign.status == "scheduled"

        campaign.update!(status: "draft", send_at: nil, dispatched_by_user: nil)
        DomainEvents.publish("campaign.unscheduled", campaign_id: campaign.id, by_user_id: by.id)
        Result.ok(campaign: campaign)
      end
    end
  end
end
