# Exceção sem código (spec §2.1): triagens elegíveis de um CPF.
module Attendances
  class EligibleTriages
    def self.call(cpf:)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      Result.ok(triages: CheckInEligibility.eligible_for(Citizen.where(cpf: digits)).to_a)
    end
  end
end
