# app/commands/campaigns/set_sms_enabled.rb
# Liga/desliga o SMS de campanha da cidade (ADR 0024 §3.4; D1). Ligar sem
# provedor configurado é permitido: os avisos saem e o SMS vira unavailable.
# Reason: :city_profile_missing (não acontece em cidade provisionada).
module Campaigns
  class SetSmsEnabled
    def self.call(enabled:, by:)
      ApplicationRecord.transaction do
        profile = CityProfile.lock.first
        next Result.fail(:city_profile_missing) unless profile

        if profile.campaigns_sms_enabled != enabled
          profile.update!(campaigns_sms_enabled: enabled)
          DomainEvents.publish("city.campaigns_sms_toggled", enabled: enabled, by_user_id: by.id)
        end
        Result.ok(enabled: enabled)
      end
    end
  end
end
