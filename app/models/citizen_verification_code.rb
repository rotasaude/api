# Código que o cidadão mostra no balcão (spec 2026-09-24 §2.2, §3). A lógica de
# emitir e conferir mora nos comandos Citizens::IssueVerificationCode e
# Citizens::VerificationCodeMatch.
class CitizenVerificationCode < ApplicationRecord
  TTL = 10.minutes
  MAX_ATTEMPTS = 5

  belongs_to :citizen

  scope :usable, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(citizen_id, code)
    key = Rails.application.key_generator.generate_key("citizen-verification-code", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, "#{citizen_id}:#{code}")
  end
end
