# Perfil declarado pelo cidadão (ADR 0027; spec 2026-10-05 §5.4), no padrão de
# SetNeighborhood: lock no par, evento só com o id e só quando muda. Perfil
# conferido no posto (verified) só muda no posto. Reasons: :profile_verified e
# as de ProfileValues.
module Citizens
  class SetProfile
    def self.call(citizen:, birth_date:, sex:, gender_identity:)
      values = ProfileValues.call(birth_date: birth_date, sex: sex, gender_identity: gender_identity)
      return values if values.failure?

      result = nil
      ApplicationRecord.transaction do
        citizen.lock!
        next result = Result.fail(:profile_verified) if citizen.profile_source == "verified"

        citizen.assign_attributes(values.payload.merge(profile_source: "declared"))
        if citizen.changed?
          citizen.save!
          DomainEvents.publish("citizen.profile_changed", citizen_id: citizen.id)
        end
        result = Result.ok(citizen: citizen)
      end
      result
    end
  end
end
