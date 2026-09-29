# Chave de SMS da cidade (ADR 0024 §3.4): nasce desligada. Sem city_profile
# (bancos de teste), vale desligada.
module Campaigns
  module SmsSetting
    def self.enabled?
      CityProfile.current&.campaigns_sms_enabled == true
    end
  end
end
