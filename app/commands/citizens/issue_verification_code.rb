# "Validar no posto" no wpda (spec 2026-09-24 §4): um código de 6 dígitos,
# 10 minutos, que invalida os anteriores do mesmo par. Reasons: :already_verified.
module Citizens
  class IssueVerificationCode
    def self.call(citizen:)
      return Result.fail(:already_verified) if citizen.active_verification

      code = format("%06d", SecureRandom.random_number(1_000_000))
      record = nil
      ApplicationRecord.transaction do
        CitizenVerificationCode.usable.where(citizen: citizen).update_all(expires_at: Time.current)
        record = CitizenVerificationCode.create!(
          citizen: citizen,
          code_digest: CitizenVerificationCode.digest(citizen.id, code),
          expires_at: CitizenVerificationCode::TTL.from_now
        )
      end
      Result.ok(code: code, expires_at: record.expires_at)
    end
  end
end
