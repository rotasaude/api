# Token FHIR do prestador (ADR 0036): mostrado uma vez; só o SHA-256 fica;
# girar troca o anterior; revogar desliga. Evento só com o id.
module Exams
  module RotateFhirToken
    module_function

    def call(provider:)
      token = SecureRandom.urlsafe_base64(32)
      provider.update!(fhir_token_digest: ExamProvider.digest(token), fhir_token_rotated_at: Time.current, fhir_token_revoked_at: nil)
      DomainEvents.publish("exam_provider.fhir_token_rotated", exam_provider_id: provider.id)
      Result.ok(token: token)
    end

    def revoke(provider:)
      return Result.ok unless provider.fhir_token_active?

      provider.update!(fhir_token_revoked_at: Time.current)
      DomainEvents.publish("exam_provider.fhir_token_revoked", exam_provider_id: provider.id)
      Result.ok
    end
  end
end
