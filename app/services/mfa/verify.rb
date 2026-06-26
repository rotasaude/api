require "rotp"

module Mfa
  module Verify
    DRIFT = 30  # segundos — tolera relógio mal sincronizado

    def self.call(user, code:)
      return false if user.otp_secret.blank? || code.blank?
      return true if totp_valid?(user, code)
      consume_recovery_code(user, code)
    end

    def self.totp_valid?(user, code)
      ROTP::TOTP.new(user.otp_secret).verify(code.to_s.gsub(/\s+/, ""), drift_behind: DRIFT, drift_ahead: DRIFT).present?
    end

    def self.consume_recovery_code(user, code)
      remaining = user.otp_recovery_codes.dup
      idx = remaining.find_index { |hashed| BCrypt::Password.new(hashed) == code.to_s.downcase }
      return false unless idx

      remaining.delete_at(idx)
      user.update!(otp_recovery_codes: remaining)
      true
    end
  end
end
