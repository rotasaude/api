# app/commands/signatures/unlink.rb
# Desvínculo (ADR 0032; spec §5, step-up no controller): o certificado vira
# unlinked e a sessão ativa cai. Pedidos pendentes ficam pendentes (o autor
# pode vincular de novo ou devolver ao papel).
module Signatures
  module Unlink
    module_function

    def call(user:, now: Time.current)
      ApplicationRecord.transaction do
        certificate = SignerCertificate.active.lock.find_by(user_id: user.id)
        next Result.fail(:certificate_not_linked) unless certificate

        certificate.update!(status: "unlinked")
        SignatureSession.active.where(user_id: user.id).update_all(status: "revoked", updated_at: now)
        DomainEvents.publish("signature.certificate_unlinked", certificate_id: certificate.id, user_id: user.id,
                                                                provider: certificate.provider)
        Result.ok(certificate: certificate)
      end
    end
  end
end
