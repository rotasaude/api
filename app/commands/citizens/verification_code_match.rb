# Confere CPF + código digitados no balcão (spec 2026-09-24 §4, §6). Não
# consome o código. Um código errado conta uma tentativa em TODOS os códigos
# utilizáveis do CPF (não dá para saber de qual par era a tentativa). Código de
# outro CPF e CPF sem código respondem igual a código errado.
# Reasons: :invalid_cpf, :invalid_code, :code_expired, :code_exhausted.
module Citizens
  class VerificationCodeMatch
    RECENT = 24.hours

    def self.call(cpf:, code:, lock: false, purpose: "verification")
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits
      return Result.fail(:invalid_code) unless code.to_s.match?(/\A\d{6}\z/)

      citizens = Citizen.where(cpf: digits)
      candidates = CitizenVerificationCode.usable.for_purpose(purpose).where(citizen: citizens).order(:created_at)
      candidates = candidates.lock if lock
      candidates = candidates.to_a

      if candidates.empty?
        recent = CitizenVerificationCode.for_purpose(purpose).where(citizen: citizens)
                                         .where("created_at > ?", RECENT.ago)
                                         .any? { |c| ActiveSupport::SecurityUtils.secure_compare(c.code_digest, CitizenVerificationCode.digest(c.citizen_id, code.to_s)) }
        return Result.fail(recent ? :code_expired : :invalid_code)
      end

      hit = candidates.find do |c|
        ActiveSupport::SecurityUtils.secure_compare(c.code_digest, CitizenVerificationCode.digest(c.citizen_id, code.to_s))
      end

      if hit.nil?
        CitizenVerificationCode.where(id: candidates.map(&:id)).update_all("attempts = attempts + 1")
        return Result.fail(:invalid_code)
      end
      return Result.fail(:code_exhausted) if hit.attempts >= CitizenVerificationCode::MAX_ATTEMPTS

      Result.ok(citizen: hit.citizen, verification_code: hit, triage: hit.triage)
    end
  end
end
