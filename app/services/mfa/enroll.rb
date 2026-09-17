require "rotp"

module Mfa
  module Enroll
    RECOVERY_COUNT = 10
    RECOVERY_LEN   = 10

    def self.call(user)
      secret = ROTP::Base32.random
      codes  = Array.new(RECOVERY_COUNT) { SecureRandom.alphanumeric(RECOVERY_LEN).downcase }
      hashed = codes.map { |c| BCrypt::Password.create(c).to_s }

      # `otp_enabled` só existe em User/Operator: Maintainer marca a confirmação
      # do TOTP em `otp_enabled_at` (Task 2), então este call não a toca.
      attrs = { otp_secret: secret, otp_recovery_codes: hashed }
      attrs[:otp_enabled] = false if user.respond_to?(:otp_enabled=)
      user.update!(attrs)

      {
        secret: secret,
        otpauth_uri: ROTP::TOTP.new(secret, issuer: "Rota Saúde").provisioning_uri(user.email_address),
        recovery_codes: codes
      }
    end
  end
end
