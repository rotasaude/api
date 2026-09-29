# Enviar agora (spec 2026-09-29 §5.2): draft → sending com FOR UPDATE, público
# validado e com 5 telefones ou mais, DispatchJob na fila depois do commit.
# Reasons: :invalid_transition, :invalid_audience, :below_minimum.
module Campaigns
  class Send
    def self.call(campaign:, by:)
      ApplicationRecord.transaction do
        campaign.lock!
        next Result.fail(:invalid_transition) unless campaign.status == "draft"

        gate = SendGate.failure_for(campaign)
        next gate if gate

        campaign.update!(status: "sending", dispatched_by_user: by)
        DispatchJob.perform_later(city_slug: Current.city.slug, campaign_id: campaign.id)
        Result.ok(campaign: campaign)
      end
    end
  end
end
