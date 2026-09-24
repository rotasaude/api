# "Validar no posto" no wpda (spec 2026-09-24 §4): um código de 6 dígitos,
# 10 minutos, que invalida os anteriores do mesmo par. Reasons: :already_verified.
module Citizens
  class IssueVerificationCode
    def self.call(citizen:)
      return Result.fail(:already_verified) if citizen.active_verification

      IssueCounterCode.call(citizen: citizen, purpose: "verification")
    end
  end
end
