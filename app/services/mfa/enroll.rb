require "rotp"

module Mfa
  module Enroll
    RECOVERY_COUNT = 10
    RECOVERY_LEN   = 10

    def self.call(user)
      secret = ROTP::Base32.random
      codes  = Array.new(RECOVERY_COUNT) { SecureRandom.alphanumeric(RECOVERY_LEN).downcase }
      hashed = codes.map { |c| BCrypt::Password.create(c).to_s }

      user.update!(otp_secret: secret, otp_enabled: false, otp_recovery_codes: hashed)

      {
        secret: secret,
        otpauth_uri: ROTP::TOTP.new(secret, issuer: "Rota Saúde").provisioning_uri(user.email_address),
        recovery_codes: codes
      }
    end
  end
end
