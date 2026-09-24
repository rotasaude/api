# Valida o par no balcão (spec 2026-09-24 §2, §4). Confere e consome o código
# sob lock: dois atendentes com o mesmo código → só um valida.
module Citizens
  class Verify
    def self.call(cpf:, code:, document_checked:, by:)
      return Result.fail(:document_check_required) unless document_checked == true

      result = nil
      ApplicationRecord.transaction do
        match = VerificationCodeMatch.call(cpf: cpf, code: code, lock: true)
        next result = match if match.failure?

        citizen = match.payload[:citizen]
        if (active = citizen.active_verification)
          next result = Result.fail(:already_verified, details: { verified_at: active.verified_at })
        end

        match.payload[:verification_code].update!(consumed_at: Time.current)
        verification = CitizenVerification.create!(citizen: citizen, verified_by_user: by, verified_at: Time.current)
        citizen.update!(verification_level: "verified")
        DomainEvents.publish("citizen.verified", citizen_id: citizen.id, verification_id: verification.id,
                                                 verified_by_user_id: by.id)
        result = Result.ok(verification: verification)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_verified)
    end
  end
end
