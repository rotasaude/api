module Maintenance
  module Mutations
    class SaveProtocolDraft < CityMutation
      description "Salva uma versão de protocolo em rascunho numa cidade. O mantenedor passa a " \
                  "constar como quem editou a versão, e quem edita nunca a assina."

      argument :definition, GraphQL::Types::JSON, required: true

      def resolve(city_slug:, definition:)
        # O escalar JSON aceita qualquer valor JSON; só objeto é definição.
        # Um não-objeto vira `{}`, cujo nome ausente CityMutation recusa como
        # erro de usuário em `definition` — depois do escopo, antes de auditar.
        definition = definition.is_a?(Hash) ? definition.to_h.deep_stringify_keys : {}

        in_city(city_slug: city_slug, event: "maintenance.protocol.draft_saved", module_name: "protocol",
                rejection_path: "definition", field_paths: { protocol_key: "definition", version: "definition" },
                protocol_key: definition["name"], version: definition["version"],
                changed_fields: [ "definition" ]) do |actor, correlation_id|
          Protocols::SaveDraft.call(definition: definition, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
