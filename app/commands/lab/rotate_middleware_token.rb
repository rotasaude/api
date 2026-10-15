# Token do middleware (contrato §3): mostrado uma vez; só o SHA-256 fica;
# girar revoga o anterior; evento só com o id do laboratório.
module Lab
  module RotateMiddlewareToken
    module_function

    def call(provider:, by:, simulated: false, token: SecureRandom.urlsafe_base64(32))
      ApplicationRecord.transaction do
        provider.lock!
        LabMiddlewareToken.active.where(exam_provider_id: provider.id).update_all(revoked_at: Time.current)
        LabMiddlewareToken.create!(exam_provider: provider, token_digest: LabMiddlewareToken.digest(token), simulated: simulated,
                                   created_by_user: by, created_at: Time.current)
        DomainEvents.publish("lab_middleware.token_rotated", exam_provider_id: provider.id)
      end
      Result.ok(token: token)
    end

    def revoke(provider:)
      revoked = LabMiddlewareToken.active.where(exam_provider_id: provider.id).update_all(revoked_at: Time.current)
      DomainEvents.publish("lab_middleware.token_revoked", exam_provider_id: provider.id) if revoked.positive?
      Result.ok
    end
  end
end
