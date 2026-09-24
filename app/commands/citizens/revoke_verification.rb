# Desfaz uma validação (spec 2026-09-24 §2.6): só municipal_admin (checado no
# controller), nunca quem validou; motivo ≥ 10 caracteres.
module Citizens
  class RevokeVerification
    MIN_REASON = 10

    def self.call(verification:, reason:, by:)
      return Result.fail(:already_revoked) unless verification.active?
      return Result.fail(:own_verification) if verification.verified_by_user_id == by.id
      return Result.fail(:reason_too_short) if reason.to_s.strip.length < MIN_REASON

      outcome = ApplicationRecord.transaction do
        verification.lock!
        break :already_revoked unless verification.active?

        verification.update!(revoked_at: Time.current, revoked_by_user: by, revoke_reason: reason.to_s.strip)
        verification.citizen.update!(verification_level: "declared")
        DomainEvents.publish("citizen.verification_revoked", citizen_id: verification.citizen_id,
                                                             verification_id: verification.id,
                                                             revoked_by_user_id: by.id)
        :revoked
      end
      return Result.fail(:already_revoked) if outcome == :already_revoked

      Result.ok(verification: verification)
    end
  end
end
