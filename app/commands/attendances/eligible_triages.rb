# Exceção sem código (spec §2.1): triagens elegíveis de um CPF, mais os
# horários de hoje da unidade quando informada (spec 2026-09-25 §2.10).
module Attendances
  class EligibleTriages
    def self.call(cpf:, by: nil, health_unit_id: nil)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits

      citizens = Citizen.where(cpf: digits)
      triages = CheckInEligibility.eligible_for(citizens).to_a
      appointments = health_unit_id.present? ? AppointmentCheckInEligibility.eligible_for(citizens, health_unit_id).to_a : []
      DomainEvents.publish("attendance.exception_searched", by_user_id: by&.id,
                                                            result_count: triages.size + appointments.size)
      Result.ok(triages: triages, appointments: appointments)
    end
  end
end
