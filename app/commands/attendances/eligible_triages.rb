# Exceção sem código (spec §2.1): triagens elegíveis de um CPF.
module Attendances
  class EligibleTriages
    def self.call(cpf:, by: nil)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      triages = CheckInEligibility.eligible_for(Citizen.where(cpf: digits)).to_a
      DomainEvents.publish("attendance.exception_searched", by_user_id: by&.id, result_count: triages.size)
      Result.ok(triages: triages)
    end
  end
end
