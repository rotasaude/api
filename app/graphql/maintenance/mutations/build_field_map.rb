module Maintenance
  module Mutations
    # ADR 0053 (contrato do 24c §10; Q19, Q22, Q24): pede a geração do mapa de
    # campo de uma cidade. Escrita de PLATAFORMA sobre uma cidade (on_platform):
    # o escopo da credencial é conferido, a tentativa é auditada e a cidade
    # precisa existir e estar ativa — mas o banco dela não é aberto. Marca a
    # linha em `building` e enfileira o job; o arquivo publicado, se houver,
    # continua servido. Sem base pronta, o job grava `failed base_missing`.
    # Sem TOTP nem step-up.
    class BuildFieldMap < CityMutation
      description "Gera (ou gera de novo) o mapa offline de campo de uma cidade."

      field :field_map, Types::FieldMapType, null: true

      def resolve(city_slug:)
        on_platform(city_slug: city_slug, event: "maintenance.field_map.build_requested", module_name: "field_maps",
                    payload_from_result: ->(result) { { field_map: result.payload[:field_map] } }) do |city, _actor, _id|
          Result.ok(field_map: FieldMaps::Request.build!(city))
        end
      end
    end
  end
end
