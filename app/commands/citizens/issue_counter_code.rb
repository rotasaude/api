# Código do balcão (ADR 0017/0018): 6 dígitos, 10 minutos, um ativo por
# cidadão — gerar qualquer código invalida o anterior, de qualquer finalidade.
module Citizens
  class IssueCounterCode
    def self.call(citizen:, purpose:, triage: nil)
      code = format("%06d", SecureRandom.random_number(1_000_000))
      record = nil
      ApplicationRecord.transaction do
        CitizenVerificationCode.usable.where(citizen: citizen).update_all(expires_at: Time.current)
        record = CitizenVerificationCode.create!(
          citizen: citizen, purpose: purpose.to_s, triage: triage,
          code_digest: CitizenVerificationCode.digest(citizen.id, code),
          expires_at: CitizenVerificationCode::TTL.from_now
        )
      end
      Result.ok(code: code, expires_at: record.expires_at)
    end
  end
end
