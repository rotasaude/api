# Completar os nomes de par já validado (ADR 0031; contratos §2 e §9; spec
# §12: pares validados antes do deploy ou por cliente antigo). Feito no
# check-in, com a validação ativa. O paciente ligado passa a usar os nomes
# (Patients::Resolve.refresh!, Task 5).
module Citizens
  module CompleteNames
    module_function

    def call(verification:, full_name:, social_name:, mother_name:, by:)
      names = NameValues.call(full_name: full_name, social_name: social_name, mother_name: mother_name)
      return names if names.failure?

      ApplicationRecord.transaction do
        verification.lock!
        next Result.fail(:already_revoked) unless verification.active?

        citizen = verification.citizen
        citizen.lock!
        citizen.update!(names.payload)
        Patients::Resolve.refresh!(Patient.lock.find(citizen.patient_id)) if citizen.patient_id
        DomainEvents.publish("citizen.profile_changed", citizen_id: citizen.id)
        Result.ok(citizen: citizen)
      end
    end
  end
end
