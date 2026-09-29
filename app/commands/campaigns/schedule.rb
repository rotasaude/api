# Agendar (§5.2): draft → scheduled, send_at de 5 minutos a 90 dias à frente.
# Reasons: :invalid_transition, :invalid_send_at, :invalid_audience, :below_minimum.
module Campaigns
  class Schedule
    def self.call(campaign:, send_at:, by:)
      ApplicationRecord.transaction do
        campaign.lock!
        next Result.fail(:invalid_transition) unless campaign.status == "draft"

        at = parse(send_at)
        unless at && at >= Campaign::SEND_AT_MIN_LEAD.from_now && at <= Campaign::SEND_AT_MAX_AHEAD.from_now
          next Result.fail(:invalid_send_at)
        end

        gate = SendGate.failure_for(campaign)
        next gate if gate

        campaign.update!(status: "scheduled", send_at: at, dispatched_by_user: by)
        DomainEvents.publish("campaign.scheduled", campaign_id: campaign.id, send_at: at.iso8601, by_user_id: by.id)
        Result.ok(campaign: campaign)
      end
    end

    def self.parse(value)
      return nil unless value.is_a?(String)

      Time.zone.iso8601(value)
    rescue ArgumentError
      nil
    end
  end
end
