module Maintenance
  module Types
    class CityAccountType < BaseObject
      description "Conta de staff da prefeitura, no banco da cidade — não é cidadão. " \
                   "password_digest, otp_secret e recovery codes ficam de fora por regra: " \
                   "o que serve para operar é saber SE a conta exige MFA."

      field :login, String, null: false
      field :roles, [ String ], null: false
      field :active, Boolean, null: false
      field :mfa_enrolled, Boolean, null: false
    end
  end
end
