# Código de confirmação do celular (spec 2026-09-22-web-citizen-channel §4.2).
# O SMS custa dinheiro: os limites daqui existem para que ninguém infle envios.
# `created_at` faz o papel de "enviado em".
class OtpChallenge < ApplicationRecord
  TTL = 10.minutes
  MAX_ATTEMPTS = 5
  RESEND_AFTER = 60.seconds
  DAILY_LIMIT = 5

  class TooSoon < StandardError; end
  class DailyLimit < StandardError; end

  encrypts :phone, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  def self.issue!(phone:)
    recent = where(phone: phone).where("created_at > ?", 24.hours.ago)
    raise DailyLimit if recent.count >= DAILY_LIMIT
    raise TooSoon if recent.where("created_at > ?", RESEND_AFTER.ago).exists?

    code = format("%06d", SecureRandom.random_number(1_000_000))
    challenge = create!(phone: phone, code_digest: digest(phone, code), expires_at: TTL.from_now)
    [challenge, code]
  end

  # Só o desafio mais recente e não usado do telefone vale: um reenvio
  # invalida o anterior.
  def self.verify(phone:, code:)
    challenge = where(phone: phone, consumed_at: nil).order(created_at: :desc).first
    return :missing unless challenge

    result = nil
    challenge.with_lock do
      result =
        if challenge.expires_at.past? then :expired
        elsif challenge.attempts >= MAX_ATTEMPTS then :exhausted
        elsif ActiveSupport::SecurityUtils.secure_compare(challenge.code_digest, digest(phone, code.to_s))
          challenge.update!(consumed_at: Time.current)
          :ok
        else
          challenge.increment!(:attempts)
          :invalid
        end
    end
    result
  end

  # HMAC com chave derivada do secret_key_base: um dump do banco sozinho não
  # basta para testar os 10^6 códigos possíveis.
  def self.digest(phone, code)
    key = Rails.application.key_generator.generate_key("citizen-otp", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, "#{phone}:#{code}")
  end
end
