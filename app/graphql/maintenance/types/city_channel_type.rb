module Maintenance
  module Types
    class CityChannelType < BaseObject
      description "Canal de WhatsApp da cidade. O access_token é cifrado e NUNCA sai daqui."

      field :phone_number_id, String, null: false
      field :waba_id, String, null: true
      field :display_phone_number, String, null: false
      field :active, Boolean, null: false
    end
  end
end
