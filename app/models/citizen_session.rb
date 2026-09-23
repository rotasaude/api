# Sessão do cidadão no canal web. Pertence ao TELEFONE confirmado por OTP, não
# a um CPF: a escolha da pessoa vem depois (spec §2.6). Guarda só o hash do
# token; o token viaja no cookie assinado `citizen_session`.
class CitizenSession < ApplicationRecord
  TTL = 30.days
  SLIDE_EVERY = 1.hour

  encrypts :phone, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token)
  end

  def self.start!(phone:)
    token = SecureRandom.urlsafe_base64(32)
    session = create!(phone: phone, token_digest: digest(token),
                      expires_at: TTL.from_now, last_seen_at: Time.current)
    [session, token]
  end

  def self.resume(token)
    return nil if token.blank?

    session = find_by(token_digest: digest(token))
    return nil unless session&.usable?

    session.slide!
    session
  end

  def usable?
    revoked_at.nil? && expires_at.future?
  end

  # Prazo deslizante (spec §2.6), gravado no máximo uma vez por hora.
  def slide!
    return if last_seen_at && last_seen_at > SLIDE_EVERY.ago

    update!(last_seen_at: Time.current, expires_at: TTL.from_now)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def citizens
    Citizen.where(phone: phone)
  end
end
