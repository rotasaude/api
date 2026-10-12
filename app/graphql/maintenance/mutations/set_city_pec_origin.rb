module Maintenance
  module Mutations
    # ADR 0035 (contrato §6): grava (ou apaga, com null) o endereço do PEC,
    # usado no frame-ancestors da página do PEC.
    class SetCityPecOrigin < CityMutation
      description "Grava o endereço (origem) do PEC da cidade. Nulo apaga."

      # Obrigatório e anulável: omitir é erro de validação; null apaga.
      argument :pec_origin, String, required: :nullable

      def resolve(city_slug:, pec_origin:)
        outcome = in_city(city_slug: city_slug, event: "maintenance.city.pec_config_changed", module_name: "city",
                          rejection_path: "pecOrigin", pec_field: "pec_origin") do |_actor, _correlation_id|
          PecExternal::Configure.set_origin(origin: pec_origin)
        end
        PecExternal::Configure.audit!(city_slug: city_slug, field: "pec_origin", maintainer_id: credential.maintainer.id) if outcome[:ok]
        outcome
      end
    end
  end
end
