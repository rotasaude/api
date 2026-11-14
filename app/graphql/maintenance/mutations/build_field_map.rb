module Maintenance
  module Mutations
    # ADR 0053 (contrato do 24c §10; Q19, Q22, Q24): pede a geração do mapa de
    # campo de uma cidade. Plataforma só: marca a linha em `building` e
    # enfileira o job; o arquivo publicado, se houver, continua servido. Sem
    # base pronta, o job grava `failed base_missing`. Sem TOTP nem step-up.
    class BuildFieldMap < BaseMutation
      description "Gera (ou gera de novo) o mapa offline de campo de uma cidade."

      argument :city_slug, String, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      field :field_map, Types::FieldMapType, null: true

      def resolve(city_slug:)
        map = nil
        result = audited(event: "maintenance.field_map.build_requested", module_name: "field_maps", city_slug: city_slug) do
          city = City.find_by(slug: city_slug)
          raise Rejected.new("cidade não encontrada", path: "citySlug") unless city&.status == "active"

          map = FieldMaps::Request.build!(city)
        end
        result.merge(field_map: map)
      end
    end
  end
end
