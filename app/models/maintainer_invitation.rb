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

  # Convite é EXCLUSIVO (fix round 1): emitir um novo, ou aceitar um, invalida
  # qualquer outro ainda pendente do mesmo mantenedor — "usado" aqui inclui
  # "superado", não só "aceito". Sem isto, dois links viviam ao mesmo tempo, e
  # um convite antigo ainda podia matricular TOTP ou trocar a senha de uma
  # conta já ativa.
  def self.invalidate_pending_for!(maintainer)
    maintainer.maintainer_invitations.where(used_at: nil).update_all(used_at: Time.current)
  end
end
