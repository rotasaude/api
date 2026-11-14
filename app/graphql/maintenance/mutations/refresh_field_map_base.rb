module Maintenance
  module Mutations
    # ADR 0053 (contrato do 24c §10; Q19, Q22, Q23): pede a cópia da base dos
    # mapas de campo a partir da build pública mais recente. Uma cópia por vez.
    # A base pronta atual segue valendo até a nova ficar pronta.
    class RefreshFieldMapBase < BaseMutation
      description "Atualiza a base dos mapas de campo com a build mais recente."

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      field :field_map_base, Types::FieldMapBaseType, null: true

      def resolve
        result = audited(event: "maintenance.field_map.base_refresh_requested", module_name: "field_maps") do
          raise Rejected.new("cópia em curso", path: "base") unless FieldMaps::Request.refresh_base!
        end
        result.merge(field_map_base: FieldMapBase.current)
      end
    end
  end
end
