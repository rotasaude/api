# Convite de mantenedor (spec §6): uso único, 24h. Grava só o DIGEST — o token em
# claro existe uma vez, na saída da rake, e nunca no banco nem em log.
class MaintainerInvitation < PlatformRecord
  belongs_to :maintainer

  TTL = 24.hours

  def self.digest_for(token) = OpenSSL::Digest::SHA256.hexdigest(token.to_s)

  def self.issue!(maintainer:)
    token = SecureRandom.urlsafe_base64(32)
    invitation = create!(maintainer: maintainer, token_digest: digest_for(token), expires_at: TTL.from_now)
    [ invitation, token ]
  end

  def usable? = used_at.nil? && expires_at > Time.current
end
