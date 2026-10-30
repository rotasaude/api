# Perfil do CEO (ADR 0046): tipo (I, II, III) e especialidades da unidade
# `ceo`. Um por unidade (cria ou substitui). Recusa 422 `unit_not_ceo` fora do
# tipo `ceo` e `invalid_request` com `path` do campo. Evento `ceo_profile.changed`
# só com ids.
module DentalCare
  module SaveCeoProfile
    module_function

    # params: corpo JSON. -> Result.ok(profile:) | fail(:unit_not_ceo | :invalid_request, details: { path: })
    def call(unit:, params:, by:)
      return Result.fail(:unit_not_ceo) unless unit.kind == "ceo"

      type = params["ceo_type"]
      return refuse("ceo_type") unless Catalog::CEO_TYPES.include?(type)

      specialties = params["specialties"]
      return refuse("specialties") unless specialties.is_a?(Array) && specialties.any?

      bad = specialties.index { |key| !Catalog::CEO_SPECIALTIES.include?(key) }
      return refuse("specialties[#{bad}]") if bad

      CeoProfile.transaction(requires_new: true) do
        profile = CeoProfile.find_or_initialize_by(health_unit: unit)
        profile.assign_attributes(ceo_type: type, specialties: specialties.uniq, updated_by_user: by)
        profile.save!
        DomainEvents.publish("ceo_profile.changed", health_unit_id: unit.id, user_id: by.id)
        Result.ok(profile: profile)
      end
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
