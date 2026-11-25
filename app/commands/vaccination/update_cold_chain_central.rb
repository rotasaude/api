# Edita a rede de frio municipal (módulo 27b, Q13): `{ cnes, name? }`. `cnes` é
# obrigatório na chamada (7 dígitos em texto ou null, que limpa); `name` segue a
# regra da criação (3 a 120 caracteres, único sem diferenciar caixa). CNES de
# uma `health_units.cnes` → `cnes_in_use`; o almoxarifado central pode ter o
# mesmo CNES. Sem rede de frio criada → `not_found`. O local é travado FOR UPDATE.
module Vaccination
  module UpdateColdChainCentral
    module_function

    # -> Result.ok(location:) | fail(:invalid_request, details: { path: }) | fail(:cnes_in_use) | fail(:not_found)
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      return refuse("cnes") unless attrs.key?("cnes") && Pharmacy::SaveLocation.valid_cnes?(attrs["cnes"])

      name = attrs["name"]
      name = name.strip if name.is_a?(String)
      return refuse("name") if attrs.key?("name") && !(name.is_a?(String) && CreateColdChainCentral::NAME_LENGTH.cover?(name.length))

      StockLocation.transaction(requires_new: true) do
        location = StockLocation.lock.find_by(kind: "cold_chain_central")
        next Result.fail(:not_found) unless location
        next Result.fail(:cnes_in_use) if attrs["cnes"] && Pharmacy::SaveLocation.cnes_in_use?(attrs["cnes"])
        next refuse("name") if attrs.key?("name") && name != location.name &&
                               StockLocation.where.not(id: location.id).exists?([ "lower(name) = lower(?)", name ])

        location.cnes = attrs["cnes"]
        location.name = name if attrs.key?("name")
        if location.changed?
          location.updated_by_user = by
          location.save!
          DomainEvents.publish("pharmacy.settings_changed", subject: "location", stock_location_id: location.id, user_id: by.id)
        end
        Result.ok(location: location)
      end
    rescue ActiveRecord::RecordNotUnique
      refuse("name")
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
